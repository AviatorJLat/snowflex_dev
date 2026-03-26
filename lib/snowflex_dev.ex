defmodule SnowflexDev do
  @moduledoc """
  Drop-in development replacement for Snowflex using Python's snowflake-connector-python
  with externalbrowser SSO authentication via an Erlang Port.

  Implements Ecto.Adapter, Ecto.Adapter.Queryable, and Ecto.Adapter.Schema behaviours.
  Delegates to Ecto.Adapters.SQL module functions (not `use Ecto.Adapters.SQL` macro,
  which would auto-implement Transaction behaviour that Snowflake does not support).
  """

  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Schema

  @conn SnowflexDev.Ecto.Adapter.Connection

  # --- Ecto.Adapter callbacks ---

  @impl Ecto.Adapter
  defmacro __before_compile__(env) do
    Ecto.Adapters.SQL.__before_compile__(:snowflex_dev, env)
  end

  @impl Ecto.Adapter
  def ensure_all_started(config, type) do
    Ecto.Adapters.SQL.ensure_all_started(:snowflex_dev, config, type)
  end

  @impl Ecto.Adapter
  def init(config) do
    Ecto.Adapters.SQL.init(@conn, :snowflex_dev, config)
  end

  @impl Ecto.Adapter
  def checkout(meta, opts, fun) do
    Ecto.Adapters.SQL.checkout(meta, opts, fun)
  end

  @impl Ecto.Adapter
  def checked_out?(meta) do
    Ecto.Adapters.SQL.checked_out?(meta)
  end

  @impl Ecto.Adapter
  def loaders(:integer, type), do: [&int_decode/1, type]
  def loaders(:decimal, type), do: [&decimal_decode/1, type]
  def loaders(:float, type), do: [&float_decode/1, type]
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:id, type), do: [&int_decode/1, type]
  def loaders(:time, type), do: [&time_decode/1, type]
  def loaders(:time_usec, type), do: [&time_decode/1, type]
  def loaders(_, type), do: [type]

  @impl Ecto.Adapter
  def dumpers(:binary, type), do: [type, &binary_encode/1]
  def dumpers(_, type), do: [type]

  # --- Ecto.Adapter.Queryable callbacks ---

  @impl Ecto.Adapter.Queryable
  def prepare(:all, query) do
    {:cache, {System.unique_integer([:positive]), IO.iodata_to_binary(@conn.all(query))}}
  end

  def prepare(:update_all, query) do
    {:cache, {System.unique_integer([:positive]), IO.iodata_to_binary(@conn.update_all(query))}}
  end

  def prepare(:delete_all, query) do
    {:cache, {System.unique_integer([:positive]), IO.iodata_to_binary(@conn.delete_all(query))}}
  end

  @impl Ecto.Adapter.Queryable
  def execute(adapter_meta, query_meta, query, params, opts) do
    Ecto.Adapters.SQL.execute(:named, adapter_meta, query_meta, query, params, opts)
  end

  @impl Ecto.Adapter.Queryable
  def stream(adapter_meta, query_meta, query, params, opts) do
    # Build our own Stream struct directly (matching Snowflex's pattern).
    # We do NOT delegate to Ecto.Adapters.SQL.stream because the standard
    # implementation requires a transaction, which Snowflake does not support.
    # Instead, our Stream's Enumerable.reduce uses DBConnection.run for
    # connection checkout.
    {_cache, {_id, statement}} = query
    SnowflexDev.Ecto.Adapter.Stream.build(
      adapter_meta,
      IO.iodata_to_binary(statement),
      params,
      put_source(opts, query_meta)
    )
  end

  # --- Ecto.Adapter.Schema callbacks ---

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

  @impl Ecto.Adapter.Schema
  def insert_all(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders, opts) do
    Ecto.Adapters.SQL.insert_all(adapter_meta, schema_meta, @conn, header, rows, on_conflict, returning, placeholders, opts)
  end

  @impl Ecto.Adapter.Schema
  def insert(adapter_meta, schema_meta, params, on_conflict, returning, opts) do
    %{source: source, prefix: prefix} = schema_meta
    {kind, conflict_params, _} = on_conflict
    {fields, values} = :lists.unzip(params)
    sql = @conn.insert(prefix, source, fields, [fields], on_conflict, returning, [])

    Ecto.Adapters.SQL.struct(
      adapter_meta,
      @conn,
      sql,
      :insert,
      source,
      [],
      values ++ conflict_params,
      kind,
      returning,
      opts
    )
  end

  @impl Ecto.Adapter.Schema
  def update(adapter_meta, schema_meta, fields, params, returning, opts) do
    %{source: source, prefix: prefix} = schema_meta
    {fields, field_values} = :lists.unzip(fields)
    filter_values = Keyword.values(params)
    sql = @conn.update(prefix, source, fields, params, returning)

    Ecto.Adapters.SQL.struct(
      adapter_meta,
      @conn,
      sql,
      :update,
      source,
      params,
      field_values ++ filter_values,
      :raise,
      returning,
      opts
    )
  end

  @impl Ecto.Adapter.Schema
  def delete(adapter_meta, schema_meta, params, returning, opts) do
    %{source: source, prefix: prefix} = schema_meta
    filter_values = Keyword.values(params)
    sql = @conn.delete(prefix, source, params, returning)

    Ecto.Adapters.SQL.struct(
      adapter_meta,
      @conn,
      sql,
      :delete,
      source,
      params,
      filter_values,
      :raise,
      returning,
      opts
    )
  end

  # --- Private helpers ---

  defp put_source(opts, %{sources: sources}) do
    {source, _, _} = elem(sources, 0)
    Keyword.put(opts, :source, source)
  end

  defp put_source(opts, _), do: opts

  # --- Loader helpers (match Snowflex exactly, with float_decode bug fix) ---

  defp decimal_decode(nil), do: {:ok, nil}
  defp decimal_decode(dec) when is_binary(dec), do: {:ok, Decimal.new(dec)}
  defp decimal_decode(dec) when is_float(dec), do: {:ok, Decimal.from_float(dec)}
  defp decimal_decode(dec), do: {:ok, dec}

  defp int_decode(nil), do: {:ok, nil}
  defp int_decode(int) when is_binary(int), do: {:ok, String.to_integer(int)}
  defp int_decode(int), do: {:ok, int}

  defp time_decode(nil), do: {:ok, nil}
  defp time_decode(%Time{} = time), do: {:ok, time}
  defp time_decode(time) when is_binary(time), do: Time.from_iso8601(time)

  defp float_decode(nil), do: {:ok, nil}
  defp float_decode(float) when is_float(float), do: {:ok, float}
  defp float_decode(%Decimal{} = decimal), do: {:ok, Decimal.to_float(decimal)}

  defp float_decode(float) when is_binary(float) do
    {val, _} = Float.parse(float)
    {:ok, val}
  end

  defp date_decode(nil), do: {:ok, nil}
  defp date_decode(%Date{} = date), do: {:ok, date}
  defp date_decode(date) when is_binary(date), do: Date.from_iso8601(date)

  defp binary_encode(raw), do: {:ok, Base.encode16(raw)}
end
