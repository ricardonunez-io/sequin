defmodule Sequin.ConfigTest do
  use Sequin.DataCase

  alias Sequin.Accounts.Account
  alias Sequin.Config
  alias Sequin.Databases.PostgresDatabase
  alias Sequin.Databases.Sequence
  alias Sequin.Replication.PostgresReplicationSlot

  setup_all %{} do
    Application.put_env(:sequin, :self_hosted, true)
  end

  describe "playground.yml" do
    @yml """
    account:
      name: "Playground"

    users:
      - email: "admin@sequinstream.com"
        password: "sequinpassword!"

    databases:
      - name: "dune"
        username: "postgres"
        password: "postgres"
        hostname: "localhost"
        database: "dune"
        slot_name: "sequin_slot"
        publication_name: "sequin_pub"

    sequences:
      - name: "characters"
        database: "dune"
        table_schema: "public"
        table_name: "characters"
        sort_column_name: "updated_at"
    """

    test "creates database and sequence with no existing account" do
      assert :ok = Config.apply_config_from_yml(@yml)

      assert [account] = Repo.all(Account)
      assert account.name == "Playground"

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.account_id == account.id
      assert db.name == "dune"

      assert [%PostgresReplicationSlot{} = replication] = Repo.all(PostgresReplicationSlot)
      assert replication.postgres_database_id == db.id
      assert replication.slot_name == "sequin_slot"
      assert replication.publication_name == "sequin_pub"

      assert [%Sequence{} = sequence] = Repo.all(Sequence)
      assert sequence.postgres_database_id == db.id
      assert sequence.table_name == "characters"
      assert sequence.table_schema == "public"
      assert sequence.sort_column_name == "updated_at"
    end

    test "applying yml twice creates no duplicates" do
      assert :ok = Config.apply_config_from_yml(@yml)
      assert :ok = Config.apply_config_from_yml(@yml)

      assert [account] = Repo.all(Account)
      assert account.name == "Playground"

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.account_id == account.id
      assert db.name == "dune"

      assert [%PostgresReplicationSlot{} = replication] = Repo.all(PostgresReplicationSlot)
      assert replication.postgres_database_id == db.id
      assert replication.slot_name == "sequin_slot"
      assert replication.publication_name == "sequin_pub"

      assert [%Sequence{} = sequence] = Repo.all(Sequence)
      assert sequence.postgres_database_id == db.id
      assert sequence.table_name == "characters"
    end
  end

  describe "databases" do
    test "creates a database" do
      assert :ok =
               Config.apply_config_from_yml("""
               databases:
                 - name: "dune"
                   username: "postgres"
                   password: "postgres"
                   hostname: "localhost"
                   database: "dune"
                   slot_name: "sequin_slot"
                   publication_name: "sequin_pub"
               """)

      assert [account] = Repo.all(Account)
      assert account.name == "Configured by Sequin"

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.account_id == account.id
      assert db.name == "dune"
    end

    test "updates a database" do
      assert :ok =
               Config.apply_config_from_yml("""
               databases:
                 - name: "dune"
                   username: "postgres"
                   password: "postgres"
                   hostname: "localhost"
                   database: "dune"
                   slot_name: "sequin_slot"
                   publication_name: "sequin_pub"
               """)

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.pool_size == 3

      assert :ok =
               Config.apply_config_from_yml("""
               databases:
                 - name: "dune"
                   username: "postgres"
                   password: "postgres"
                   hostname: "localhost"
                   database: "dune"
                   pool_size: 5
               """)

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.name == "dune"
      assert db.pool_size == 5
    end
  end
end
