defmodule Mariaex.Query do
  @moduledoc """
  Query struct returned from a successfully prepared query. Its fields are:

    * `name` - The name of the prepared statement;
    * `statement` - The prepared statement;
    * `param_formats` - List of formats for each parameters encoded to;
    * `encoders` - List of anonymous functions to encode each parameter;
    * `columns` - The column names;
    * `result_formats` - List of formats for each column is decoded from;
    * `decoders` - List of anonymous functions to decode each column;
    * `types` - The type server table to fetch the type information from;
  """
  #@type t :: %__MODULE__{
  #  name:           iodata,
  #  name:           nil | :text | :binary,
  #  statement:      iodata,
  #  param_formats:  [:binary | :text] | nil,
  #  encoders:       [Mariaex.Types.oid] | [(term -> iodata)] | nil,
  #  columns:        [String.t] | nil,
  #  result_formats: [:binary | :text] | nil,
  #  decoders:       [Mariaex.Types.oid] | [(binary -> term)] | nil,
  #  types:          Mariaex.TypeServer.table | nil}
  # {:query, statement, params, opts}


  defstruct name: "",
            reserved?: false,
            type: nil,
            statement: "",
            statement_id: nil,
            parameter_types: [],
            types: []
end

defimpl DBConnection.Query, for: Mariaex.Query do
  @moduledoc """
  Implementation of `DBConnection.Query` protocol.
  """
  import Mariaex.Coder.Utils
  alias Mariaex.Messages

  @doc """
  Parse a query.

  This function is called to parse a query term before it is prepared.
  """
  def parse(%{name: name, statement: statement} = query, _) do
    %{query | name: IO.iodata_to_binary(name), statement: IO.iodata_to_binary(statement)}
  end

  @doc """
  Describe a query.

  This function is called to describe a query after it is prepared.
  """
  def describe(query, _res) do
    query
  end

  @doc """
  Encode parameters using a query.

  This function is called to encode a query before it is executed.
  """
  def encode(%Mariaex.Query{types: nil} = query, _params, _opts) do
    raise ArgumentError, "query #{inspect query} has not been prepared"
  end
  def encode(%Mariaex.Query{type: :binary, parameter_types: parameter_types} = query, params, _opts) do
    if length(params) == length(parameter_types) do
      parameter_types |> Enum.zip(params) |> parameters_to_binary()
    else
      raise ArgumentError, "parameters must be of length #{length params} for query #{inspect query}"
    end
  end
  def encode(%Mariaex.Query{type: :text}, params, _opts) do
    params
  end

  defp parameters_to_binary([]), do: <<>>
  defp parameters_to_binary(params) do
    set = {<<>>, <<>>, <<>>}
    {nullbits, typesbin, valuesbin} = Enum.reduce(params, set, fn(p, acc) -> encode_params(p, acc) end)
    << null_map_to_mysql(nullbits, <<>>) :: binary, 1 :: 8, typesbin :: binary, valuesbin :: binary >>
  end

  defp encode_params({_, param}, {nullbits, typesbin, valuesbin}) do
    {nullbit, type, value} = encode_param(param)
    {<< nullbits :: bitstring, nullbit :: 1>>,
     << typesbin :: binary, Messages.__type__(:id, type) :: 16-little >>,
     << valuesbin :: binary, value :: binary >>}
  end

  defp encode_param(nil),
    do: {1, :field_type_null, ""}
  defp encode_param(bin) when is_binary(bin),
    do: {0, :field_type_blob, << to_length_encoded_integer(byte_size(bin)) :: binary, bin :: binary >>}
  defp encode_param(int) when is_integer(int),
    do: {0, :field_type_longlong, << int :: 64-little >>}
  defp encode_param(float) when is_float(float),
    do: {0, :field_type_double, << float :: 64-little-float >>}
  defp encode_param(true),
    do: {0, :field_type_tiny, << 01 >>}
  defp encode_param(false),
    do: {0, :field_type_tiny, << 00 >>}
  defp encode_param(%Decimal{} = value) do
    bin = Decimal.to_string(value, :normal)
    {0, :field_type_newdecimal, << to_length_encoded_integer(byte_size(bin)) :: binary, bin :: binary >>}
  end
  defp encode_param({year, month, day}),
    do: {0, :field_type_date, << 4::8-little, year::16-little, month::8-little, day::8-little>>}
  defp encode_param({hour, min, sec, 0}),
    do: {0, :field_type_time, << 8 :: 8-little, 0 :: 8-little, 0 :: 32-little, hour :: 8-little, min :: 8-little, sec :: 8-little >>}
  defp encode_param({hour, min, sec, msec}),
    do: {0, :field_type_time, << 12 :: 8-little, 0 :: 8-little, 0 :: 32-little, hour :: 8-little, min :: 8-little, sec :: 8-little, msec :: 32-little>>}
  defp encode_param({{year, month, day}, {hour, min, sec, 0}}),
    do: {0, :field_type_datetime, << 7::8-little, year::16-little, month::8-little, day::8-little, hour::8-little, min::8-little, sec::8-little>>}
  defp encode_param({{year, month, day}, {hour, min, sec, msec}}),
    do: {0, :field_type_datetime, <<11::8-little, year::16-little, month::8-little, day::8-little, hour::8-little, min::8-little, sec::8-little, msec::32-little>>}
  defp encode_param(other),
    do: raise ArgumentError, "query has invalid parameter #{inspect other}"

  defp null_map_to_mysql(<<byte :: 1-bytes, rest :: bits>>, acc) do
    null_map_to_mysql(rest, << acc :: bytes, reverse_bits(byte, "") :: bytes >>)
  end
  defp null_map_to_mysql(bits, acc) do
    padding = rem(8 - bit_size(bits), 8)
    << acc :: binary, 0 :: size(padding), reverse_bits(bits, "") :: bits >>
  end

  defp reverse_bits(<<>>, acc),
    do: acc
  defp reverse_bits(<<h::1, t::bits>>, acc),
    do: reverse_bits(t, <<h::1, acc::bits>>)

  def decode(_, %{rows: nil} = res, _), do: res
  def decode(%Mariaex.Query{statement: statement}, {res, types}, opts) do
    command = Mariaex.Protocol.get_command(statement)
    if command in [:create, :insert, :replace, :update, :delete, :drop, :begin, :commit, :rollback] do
      %Mariaex.Result{res | command: command, rows: nil}
    else
      mapper = opts[:decode_mapper] || fn x -> x end
      %Mariaex.Result{rows: rows} = res
      types = Enum.reverse(types)
      decoded = do_decode(rows, types, mapper)
      %Mariaex.Result{res | command: command,
                            rows: decoded,
                            columns: (for {type, _} <- types, do: type),
                            num_rows: length(decoded)}
    end
  end

  ## helpers

  def do_decode(_, types, mapper \\ fn x -> x end)
  def do_decode(rows, types, mapper) do
    rows |> Enum.reduce([], &([(decode_bin_rows(&1, types) |> mapper.()) | &2]))
  end

  def decode_bin_rows(packet, fields) do
    nullbin_size = div(length(fields) + 7 + 2, 8)
    << 0 :: 8, nullbin :: size(nullbin_size)-binary, rest :: binary >> = packet
    nullbin = null_map_from_mysql(nullbin)
    decode_bin_rows(rest, fields, nullbin, [])
  end
  def decode_bin_rows(<<>>, [], _, acc) do
    Enum.reverse(acc)
  end
  def decode_bin_rows(packet, [_ | fields], << 1 :: 1, nullrest :: bits >>, acc) do
    decode_bin_rows(packet, fields, nullrest, [nil | acc])
  end
  def decode_bin_rows(packet, [{_name, type} | fields], << 0 :: 1, nullrest :: bits >>, acc) do
    {value, next} = handle_decode_bin_rows(Messages.__type__(:type, type), packet)
    decode_bin_rows(next, fields, nullrest, [value | acc])
  end

  defp handle_decode_bin_rows({:string, _mysql_type}, packet),              do: length_encoded_string(packet)
  defp handle_decode_bin_rows({:integer, :field_type_tiny}, packet),        do: parse_int_packet(packet, 8)
  defp handle_decode_bin_rows({:integer, :field_type_short}, packet),       do: parse_int_packet(packet, 16)
  defp handle_decode_bin_rows({:integer, :field_type_int24}, packet),       do: parse_int_packet(packet, 32)
  defp handle_decode_bin_rows({:integer, :field_type_long}, packet),        do: parse_int_packet(packet, 32)
  defp handle_decode_bin_rows({:integer, :field_type_longlong}, packet),    do: parse_int_packet(packet, 64)
  defp handle_decode_bin_rows({:integer, :field_type_year}, packet),        do: parse_int_packet(packet, 16)
  defp handle_decode_bin_rows({:time, :field_type_time}, packet),           do: parse_time_packet(packet)
  defp handle_decode_bin_rows({:date, :field_type_date}, packet),           do: parse_date_packet(packet)
  defp handle_decode_bin_rows({:timestamp, :field_type_datetime}, packet),  do: parse_datetime_packet(packet)
  defp handle_decode_bin_rows({:timestamp, :field_type_timestamp}, packet), do: parse_datetime_packet(packet)
  defp handle_decode_bin_rows({:decimal, :field_type_newdecimal}, packet),  do: parse_decimal_packet(packet)
  defp handle_decode_bin_rows({:float, :field_type_float}, packet),         do: parse_float_packet(packet, 32)
  defp handle_decode_bin_rows({:float, :field_type_double}, packet),        do: parse_float_packet(packet, 64)

  defp parse_float_packet(packet, size) do
    << value :: size(size)-float-little, rest :: binary >> = packet
    {value, rest}
  end

  defp parse_int_packet(packet, size) do
    << value :: size(size)-little-signed, rest :: binary >> = packet
    {value, rest}
  end

  defp parse_decimal_packet(packet) do
    << length,  raw_value :: size(length)-little-binary, rest :: binary >> = packet
    value = Decimal.new(raw_value)
    {value, rest}
  end

  defp parse_time_packet(packet) do
    case packet do
      << 0 :: 8-little, rest :: binary >> ->
        {{0, 0, 0, 0}, rest}
      << 8 :: 8-little, _ :: 8-little, _ :: 32-little, hour :: 8-little, min :: 8-little, sec :: 8-little, rest :: binary >> ->
        {{hour, min, sec, 0}, rest}
     << 12::8, _ :: 32-little, _ :: 8-little, hour :: 8-little, min :: 8-little, sec :: 8-little, msec :: 32-little, rest :: binary >> ->
        {{hour, min, sec, msec}, rest}
    end
  end

  defp parse_date_packet(packet) do
    case packet do
      << 0 :: 8-little, rest :: binary >> ->
        {{0, 0, 0}, rest}
      << 4 :: 8-little, year :: 16-little, month :: 8-little, day :: 8-little, rest :: binary >> ->
        {{year, month, day}, rest}
    end
  end

  defp parse_datetime_packet(packet) do
    case packet do
      << 0 :: 8-little, rest :: binary >> ->
        {{{0, 0, 0}, {0, 0, 0, 0}}, rest}
      << 4 :: 8-little, year :: 16-little, month :: 8-little, day :: 8-little, rest :: binary >> ->
        {{{year, month, day}, {0, 0, 0, 0}}, rest}
      << 7 :: 8-little, year :: 16-little, month :: 8-little, day :: 8-little, hour :: 8-little, min :: 8-little, sec :: 8-little, rest :: binary >> ->
        {{{year, month, day}, {hour, min, sec, 0}}, rest}
      << 11 :: 8-little, year :: 16-little, month :: 8-little, day :: 8-little, hour :: 8-little, min :: 8-little, sec :: 8-little, msec :: 32-little, rest :: binary >> ->
        {{{year, month, day}, {hour, min, sec, msec}}, rest}
    end
  end

  defp null_map_from_mysql(nullbin) do
    << f :: 1, e :: 1, d :: 1, c :: 1, b :: 1, a ::1, _ :: 2, rest :: binary >> = nullbin
    reversebin = for << x :: 8-bits <- rest >>, into: <<>> do
      << i :: 1, j :: 1, k :: 1, l :: 1, m :: 1, n :: 1, o :: 1, p :: 1 >> = x
      << p :: 1, o :: 1, n :: 1, m :: 1, l :: 1, k :: 1, j :: 1, i :: 1 >>
    end
    << a :: 1, b :: 1, c :: 1, d :: 1, e :: 1, f :: 1, reversebin :: binary >>
  end
end

defimpl String.Chars, for: Mariaex.Query do
  def to_string(%Mariaex.Query{statement: statement}) do
    IO.iodata_to_binary(statement)
  end
end