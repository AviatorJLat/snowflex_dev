defmodule SnowflexDev.EctoAdapterTest do
  use ExUnit.Case, async: true

  describe "loaders/2 - integer" do
    test "integer loader decodes nil" do
      [decode_fn, :integer] = SnowflexDev.loaders(:integer, :integer)
      assert decode_fn.(nil) == {:ok, nil}
    end

    test "integer loader decodes string" do
      [decode_fn, :integer] = SnowflexDev.loaders(:integer, :integer)
      assert decode_fn.("42") == {:ok, 42}
    end

    test "integer loader passes through integer" do
      [decode_fn, :integer] = SnowflexDev.loaders(:integer, :integer)
      assert decode_fn.(42) == {:ok, 42}
    end
  end

  describe "loaders/2 - decimal" do
    test "decimal loader decodes nil" do
      [decode_fn, :decimal] = SnowflexDev.loaders(:decimal, :decimal)
      assert decode_fn.(nil) == {:ok, nil}
    end

    test "decimal loader decodes string" do
      [decode_fn, :decimal] = SnowflexDev.loaders(:decimal, :decimal)
      assert decode_fn.("1.5") == {:ok, Decimal.new("1.5")}
    end

    test "decimal loader decodes float" do
      [decode_fn, :decimal] = SnowflexDev.loaders(:decimal, :decimal)
      assert decode_fn.(1.5) == {:ok, Decimal.from_float(1.5)}
    end
  end

  describe "loaders/2 - float" do
    test "float loader decodes nil" do
      [decode_fn, :float] = SnowflexDev.loaders(:float, :float)
      assert decode_fn.(nil) == {:ok, nil}
    end

    test "float loader decodes float" do
      [decode_fn, :float] = SnowflexDev.loaders(:float, :float)
      assert decode_fn.(1.5) == {:ok, 1.5}
    end

    test "float loader decodes string" do
      [decode_fn, :float] = SnowflexDev.loaders(:float, :float)
      assert decode_fn.("1.5") == {:ok, 1.5}
    end

    test "float loader decodes Decimal" do
      [decode_fn, :float] = SnowflexDev.loaders(:float, :float)
      assert decode_fn.(Decimal.new("1.5")) == {:ok, 1.5}
    end
  end

  describe "loaders/2 - date" do
    test "date loader decodes nil" do
      [decode_fn, :date] = SnowflexDev.loaders(:date, :date)
      assert decode_fn.(nil) == {:ok, nil}
    end

    test "date loader passes through Date struct" do
      [decode_fn, :date] = SnowflexDev.loaders(:date, :date)
      assert decode_fn.(~D[2024-01-15]) == {:ok, ~D[2024-01-15]}
    end

    test "date loader decodes ISO 8601 string" do
      [decode_fn, :date] = SnowflexDev.loaders(:date, :date)
      assert decode_fn.("2024-01-15") == {:ok, ~D[2024-01-15]}
    end
  end

  describe "loaders/2 - time" do
    test "time loader decodes nil" do
      [decode_fn, :time] = SnowflexDev.loaders(:time, :time)
      assert decode_fn.(nil) == {:ok, nil}
    end

    test "time loader passes through Time struct" do
      [decode_fn, :time] = SnowflexDev.loaders(:time, :time)
      assert decode_fn.(~T[10:30:00]) == {:ok, ~T[10:30:00]}
    end

    test "time loader decodes ISO 8601 string" do
      [decode_fn, :time] = SnowflexDev.loaders(:time, :time)
      assert decode_fn.("10:30:00") == {:ok, ~T[10:30:00]}
    end
  end

  describe "loaders/2 - id" do
    test "id loader uses int_decode (same as integer)" do
      [decode_fn, :id] = SnowflexDev.loaders(:id, :id)
      assert decode_fn.("42") == {:ok, 42}
      assert decode_fn.(nil) == {:ok, nil}
    end
  end

  describe "loaders/2 - passthrough" do
    test "unknown types pass through" do
      assert SnowflexDev.loaders(:string, :string) == [:string]
    end
  end

  describe "dumpers/2" do
    test "binary dumper encodes raw bytes to hex" do
      [:binary, encode_fn] = SnowflexDev.dumpers(:binary, :binary)
      assert encode_fn.(<<1, 2, 3>>) == {:ok, "010203"}
    end

    test "unknown types pass through" do
      assert SnowflexDev.dumpers(:string, :string) == [:string]
    end
  end

  describe "autogenerate/1" do
    test "returns nil for :id" do
      assert SnowflexDev.autogenerate(:id) == nil
    end

    test "returns UUID string for :embed_id" do
      uuid = SnowflexDev.autogenerate(:embed_id)
      assert is_binary(uuid)
      assert String.length(uuid) == 36
    end

    test "returns 16-byte binary for :binary_id" do
      bin = SnowflexDev.autogenerate(:binary_id)
      assert is_binary(bin)
      assert byte_size(bin) == 16
    end
  end

  describe "prepare/2" do
    test "prepare :all returns cache tuple with SQL string" do
      # Use Ecto's query planner to properly prepare the query struct
      # (sets sources tuple and normalizes the query) before passing to prepare/2.
      import Ecto.Query

      query = from(u in "users", select: u.id)
      {planned_query, _cast_params, _dump_params} =
        Ecto.Adapter.Queryable.plan_query(:all, SnowflexDev, query)

      {:cache, {id, sql}} = SnowflexDev.prepare(:all, planned_query)
      assert is_integer(id)
      assert is_binary(sql)
      assert sql =~ "SELECT"
      assert sql =~ "users"
    end
  end

  describe "behaviours" do
    test "SnowflexDev implements Ecto.Adapter" do
      behaviours =
        SnowflexDev.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ecto.Adapter in behaviours
    end

    test "SnowflexDev implements Ecto.Adapter.Queryable" do
      behaviours =
        SnowflexDev.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ecto.Adapter.Queryable in behaviours
    end

    test "SnowflexDev implements Ecto.Adapter.Schema" do
      behaviours =
        SnowflexDev.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ecto.Adapter.Schema in behaviours
    end
  end
end
