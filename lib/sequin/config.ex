defmodule Sequin.Config do
  @moduledoc false
  alias Sequin.Accounts
  alias Sequin.Databases
  alias Sequin.Databases.PostgresDatabase
  alias Sequin.Databases.Sequence
  alias Sequin.Error.NotFoundError
  alias Sequin.Repo

  require Logger

  @app :sequin

  def apply_config do
    Logger.info("Applying config")
    load_app()
    ensure_repo_started!()

    if config_file_path() do
      yml = File.read!(config_file_path())
      apply_config_from_yml(yml)
    end

    :ok
  end

  def apply_config_from_yml(yml) do
    case YamlElixir.read_from_string(yml) do
      {:ok, config} ->
        result =
          Repo.transaction(fn ->
            account = find_or_create_account!(config)
            databases = find_and_update_or_create_databases!(account.id, config)
            _sequences = find_or_create_sequences!(account.id, config, databases)

            # Not implemented
            _http_endpoints = create_http_endpoints!(config, databases)
            _http_push_consumers = create_http_push_consumers!(config, databases)
            _http_pull_consumers = create_http_pull_consumers!(config, databases)
          end)

        case result do
          {:ok, _} -> :ok
          {:error, error} -> raise "Failed to apply config: #{inspect(error)}"
        end

      {:error, error} ->
        Logger.error("Error reading config file: #{inspect(error)}")
        raise "Error reading config file: #{inspect(error)}"
    end
  end

  #############
  ## Account ##
  #############

  defp find_or_create_account!(config) do
    if self_hosted?() do
      do_find_or_create_account!(config)
    else
      raise "account configuration is not supported in Sequin Cloud"
    end
  end

  defp do_find_or_create_account!(%{"account" => %{"name" => name}}) do
    case Accounts.find_account(name: name) do
      {:ok, account} ->
        account

      {:error, %NotFoundError{}} ->
        {:ok, account} = Accounts.create_account(%{name: name})
        account
    end
  end

  @account_defaults %{"name" => "Configured by Sequin"}
  defp do_find_or_create_account!(%{}) do
    case Accounts.find_account(name: "Configured by Sequin") do
      {:ok, account} ->
        account

      {:error, %NotFoundError{}} ->
        {:ok, account} = Accounts.create_account(@account_defaults)
        account
    end
  end

  ###############
  ## Databases ##
  ###############

  @database_defaults %{
    "username" => "postgres",
    "password" => "postgres",
    "port" => 5432
  }

  defp find_and_update_or_create_databases!(account_id, %{"databases" => databases}) do
    Logger.info("Creating databases: #{inspect(databases, pretty: true)}")
    Enum.map(databases, &find_and_update_or_create_database!(account_id, &1))
  end

  defp find_and_update_or_create_databases!(_account_id, %{}) do
    Logger.info("No databases found in config")
    []
  end

  defp find_and_update_or_create_database!(account_id, %{"name" => name} = database_attrs) do
    account_id
    |> Databases.get_db_for_account(name)
    |> case do
      {:ok, database} -> update_database!(database, database_attrs)
      {:error, %NotFoundError{}} -> create_database!(account_id, database_attrs)
    end
  end

  defp create_database!(account_id, database) do
    database = Map.merge(@database_defaults, database)

    account_id
    |> Databases.create_db_for_account_with_lifecycle(database)
    |> case do
      {:ok, database} -> database
      {:error, error} when is_exception(error) -> raise "Failed to create database: #{Exception.message(error)}"
      {:error, %Ecto.Changeset{} = changeset} -> raise "Failed to create database: #{inspect(changeset)}"
    end
  end

  defp update_database!(database, attrs) do
    case Databases.update_db(database, attrs) do
      {:ok, database} -> database
      {:error, error} when is_exception(error) -> raise "Failed to update database: #{Exception.message(error)}"
    end
  end

  ###############
  ## Sequences ##
  ###############

  defp find_or_create_sequences!(account_id, %{"sequences" => sequences}, databases) do
    Logger.info("Creating sequences: #{inspect(sequences, pretty: true)}")

    Enum.map(sequences, fn sequence ->
      database = database_for_sequence!(sequence, databases)
      find_or_create_sequence!(account_id, database, sequence)
    end)
  end

  defp find_or_create_sequences!(_account_id, _config, _databases) do
    Logger.info("No sequences found in config")
    []
  end

  defp database_for_sequence!(%{"database" => database_name}, databases) do
    Sequin.Enum.find!(databases, fn database -> database.name == database_name end)
  end

  defp database_for_sequence!(%{}, _databases) do
    raise "`database` is required for each sequence and must be a valid database name"
  end

  defp find_or_create_sequence!(
         account_id,
         %PostgresDatabase{} = database,
         %{"table_schema" => table_schema, "table_name" => table_name} = sequence_attrs
       ) do
    case Databases.get_sequence_for_account(account_id, table_schema: table_schema, table_name: table_name) do
      {:ok, sequence} -> update_sequence!(sequence, database)
      {:error, %NotFoundError{}} -> create_sequence!(database, sequence_attrs)
    end
  end

  defp create_sequence!(%PostgresDatabase{id: id} = database, sequence) do
    table = table_for_sequence!(database, sequence)
    sort_column_attnum = sort_column_attnum_for_sequence!(table, sequence)

    sequence
    |> Map.put("postgres_database_id", id)
    |> Map.put("table_oid", table.oid)
    |> Map.put("sort_column_attnum", sort_column_attnum)
    |> Databases.create_sequence()
    |> case do
      {:ok, sequence} -> sequence
      {:error, error} when is_exception(error) -> raise "Failed to create sequence: #{Exception.message(error)}"
      {:error, %Ecto.Changeset{} = changeset} -> raise "Failed to create sequence: #{inspect(changeset)}"
    end
  end

  defp update_sequence!(%Sequence{} = sequence, %PostgresDatabase{} = database) do
    Databases.update_sequence_from_db(sequence, database)
  end

  defp table_for_sequence!(database, %{"table_schema" => table_schema, "table_name" => table_name}) do
    Sequin.Enum.find!(database.tables, fn table -> table.name == table_name and table.schema == table_schema end)
  end

  defp table_for_sequence!(_, %{}) do
    raise "`table` and `schema` are required for each sequence"
  end

  defp sort_column_attnum_for_sequence!(table, %{"sort_column_name" => sort_column_name}) do
    Sequin.Enum.find!(table.columns, fn column -> column.name == sort_column_name end).attnum
  end

  defp sort_column_attnum_for_sequence!(_, %{}) do
    raise "`sort_column_name` is required for each sequence"
  end

  ####################
  ## HTTP Endpoints ##
  ####################

  defp create_http_endpoints!(%{"http_endpoints" => _http_endpoints}, _databases) do
    raise "Not implemented: create_http_endpoints!/2"
  end

  defp create_http_endpoints!(%{}, _databases), do: []

  #########################
  ## HTTP Push Consumers ##
  #########################

  defp create_http_push_consumers!(%{"http_push_consumers" => _http_push_consumers}, _databases) do
    raise "Not implemented: create_http_push_consumers!/2"
  end

  defp create_http_push_consumers!(%{}, _databases), do: []

  ########################
  ## HTTP Pull Consumers ##
  ########################

  defp create_http_pull_consumers!(%{"http_pull_consumers" => _http_pull_consumers}, _databases) do
    raise "Not implemented: create_http_pull_consumers!/2"
  end

  defp create_http_pull_consumers!(%{}, _databases), do: []

  ###############
  ## Utilities ##
  ###############

  defp config_file_path do
    Application.get_env(@app, :config_file_path)
  end

  defp load_app do
    Application.load(@app)
  end

  defp ensure_repo_started! do
    Application.ensure_all_started(:sequin)
  end

  defp self_hosted? do
    Application.get_env(@app, :self_hosted, false)
  end
end
