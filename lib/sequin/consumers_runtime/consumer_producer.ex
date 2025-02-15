defmodule Sequin.ConsumersRuntime.ConsumerProducer do
  @moduledoc false
  @behaviour Broadway.Producer

  use GenStage

  alias Broadway.Message
  alias Ecto.Adapters.SQL.Sandbox
  alias Sequin.Consumers
  alias Sequin.Repo
  alias Sequin.Time

  @impl GenStage
  def init(opts) do
    consumer =
      opts |> Keyword.fetch!(:consumer) |> Repo.preload([:http_endpoint])

    if test_pid = Keyword.get(opts, :test_pid) do
      Sandbox.allow(Sequin.Repo, test_pid, self())
    end

    state = %{
      demand: 0,
      consumer: consumer,
      receive_timer: nil,
      batch_size: Keyword.get(opts, :batch_size, 10),
      batch_timeout: Keyword.get(opts, :batch_timeout, :timer.seconds(10)),
      test_pid: test_pid,
      scheduled_handle_demand: false
    }

    # Subscribe to PubSub
    Phoenix.PubSub.subscribe(Sequin.PubSub, "messages_ingested:#{consumer.id}")

    state = schedule_receive_messages(state)

    {:producer, state}
  end

  @impl GenStage
  def handle_demand(incoming_demand, %{demand: demand} = state) do
    new_state = maybe_schedule_demand(state)
    new_state = %{new_state | demand: demand + incoming_demand}

    {:noreply, [], new_state}
  end

  @impl GenStage
  def handle_info(:handle_demand, state) do
    handle_receive_messages(%{state | scheduled_handle_demand: false})
  end

  @impl GenStage
  def handle_info(:receive_messages, state) do
    new_state = schedule_receive_messages(state)
    handle_receive_messages(new_state)
  end

  @impl GenStage
  def handle_info(:messages_ingested, state) do
    new_state = maybe_schedule_demand(state)
    {:noreply, [], new_state}
  end

  defp handle_receive_messages(%{demand: demand} = state) when demand > 0 do
    {:ok, messages} = Consumers.receive_for_consumer(state.consumer, batch_size: demand)

    broadway_messages =
      Enum.map(messages, fn message ->
        %Message{
          data: message,
          acknowledger: {__MODULE__, {state.consumer, state.test_pid}, nil}
        }
      end)

    new_demand = demand - length(broadway_messages)
    new_demand = if new_demand < 0, do: 0, else: new_demand

    {:noreply, broadway_messages, %{state | demand: new_demand}}
  end

  defp handle_receive_messages(state) do
    {:noreply, [], state}
  end

  defp schedule_receive_messages(state) do
    receive_timer = Process.send_after(self(), :receive_messages, state.batch_timeout)
    %{state | receive_timer: receive_timer}
  end

  @impl Broadway.Producer
  def prepare_for_draining(%{receive_timer: receive_timer} = state) do
    if receive_timer, do: Process.cancel_timer(receive_timer)
    {:noreply, [], %{state | receive_timer: nil}}
  end

  @exponential_backoff_max :timer.minutes(3)
  def ack({consumer, test_pid}, successful, failed) do
    successful_ids = Enum.map(successful, & &1.data.ack_id)
    failed_ids = Enum.map(failed, & &1.data.ack_id)

    if test_pid do
      Sandbox.allow(Sequin.Repo, test_pid, self())
    end

    if length(successful_ids) > 0 do
      Consumers.ack_messages(consumer, successful_ids)
    end

    failed
    |> Enum.map(fn message ->
      deliver_count = message.data.deliver_count
      backoff_time = Time.exponential_backoff(:timer.seconds(1), deliver_count, @exponential_backoff_max)
      not_visible_until = DateTime.add(DateTime.utc_now(), backoff_time, :millisecond)

      {message.data.ack_id, not_visible_until}
    end)
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      ack_ids_with_not_visible_until = Map.new(chunk)
      Consumers.nack_messages_with_backoff(consumer, ack_ids_with_not_visible_until)
    end)

    if test_pid do
      send(test_pid, {__MODULE__, :ack_finished, successful_ids, failed_ids})
    end

    :ok
  end

  defp maybe_schedule_demand(%{scheduled_handle_demand: false} = state) do
    send(self(), :handle_demand)
    %{state | scheduled_handle_demand: true}
  end

  defp maybe_schedule_demand(state), do: state
end
