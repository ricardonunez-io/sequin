defmodule Sequin.DatabasesRuntime.Supervisor do
  @moduledoc """
  Supervisor for managing database-related runtime processes.
  """
  use Supervisor

  alias Sequin.DatabasesRuntime.TableProducerServer
  alias Sequin.DatabasesRuntime.TableProducerSupervisor
  alias Sequin.Repo

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(_) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  def start_table_producer(supervisor \\ TableProducerSupervisor, consumer, opts \\ []) do
    consumer = Repo.preload(consumer, :sequence, replication_slot: :postgres_database)

    default_opts = [
      consumer: consumer,
      table_oid: consumer.sequence.table_oid
    ]

    opts = Keyword.merge(default_opts, opts)

    Sequin.DynamicSupervisor.start_child(supervisor, {TableProducerServer, opts})
  end

  def stop_table_producer(supervisor \\ TableProducerSupervisor, consumer) do
    Sequin.DynamicSupervisor.stop_child(supervisor, TableProducerServer.via_tuple(consumer))
    :ok
  end

  def restart_table_producer(supervisor \\ TableProducerSupervisor, consumer, opts \\ []) do
    stop_table_producer(supervisor, consumer)
    start_table_producer(supervisor, consumer, opts)
  end

  defp children do
    [
      Sequin.DatabasesRuntime.Starter,
      Sequin.DynamicSupervisor.child_spec(name: TableProducerSupervisor)
    ]
  end
end
