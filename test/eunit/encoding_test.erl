-module(encoding_test).

% https://messente.com/documentation/tools/sms-length-calculator

-include_lib("smpp_parser/src/smpp_globals.hrl").
-include_lib("eunit/include/eunit.hrl").

encode_messages_gsm_split_test() ->
    Msg = <<"123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456|">>,
    {ok, DataCoding, MaxLength} = esmpplib_encoding:get_data_coding(Msg, undefined),
    ?assertEqual(160, byte_size(Msg)),
    ?assertEqual(?ENCODING_SCHEME_MC_SPECIFIC, DataCoding),
    ?assertEqual(160, MaxLength),
    {ok, MsgEncoded} = esmpplib_encoding:encode(DataCoding, Msg),
    ?assertEqual(161, byte_size(MsgEncoded)),
    {ok, TotalParts, Parts} = esmpplib_encoding:split_in_parts(1, MsgEncoded, MaxLength),
    ?assertEqual(2, TotalParts),
    [Part1, Part2] = Parts,
    ?assertEqual(159, byte_size(Part1)),
    ?assertEqual(14, byte_size(Part2)).

encode_messages_gsm_no_split_test() ->
    Msg = <<"1123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456">>,
    {ok, DataCoding, MaxLength} = esmpplib_encoding:get_data_coding(Msg, undefined),
    ?assertEqual(160, byte_size(Msg)),
    ?assertEqual(?ENCODING_SCHEME_MC_SPECIFIC, DataCoding),
    ?assertEqual(160, MaxLength),
    {ok, MsgEncoded} = esmpplib_encoding:encode(DataCoding, Msg),
    ?assertEqual(160, byte_size(MsgEncoded)),
    {ok, TotalParts, Parts} = esmpplib_encoding:split_in_parts(1, MsgEncoded, MaxLength),
    ?assertEqual(1, TotalParts),
    [Part1] = Parts,
    ?assertEqual(160, byte_size(Part1)).

encode_messages_ucs2_no_split_test() ->
    Msg = <<"`123456789`123456789`123456789`123456789`123456789`123456789`12345678`">>,
    {ok, DataCoding, MaxLength} = esmpplib_encoding:get_data_coding(Msg, undefined),
    ?assertEqual(70, byte_size(Msg)),
    ?assertEqual(?ENCODING_SCHEME_UCS2, DataCoding),
    ?assertEqual(140, MaxLength),
    {ok, MsgEncoded} = esmpplib_encoding:encode(DataCoding, Msg),
    ?assertEqual(140, byte_size(MsgEncoded)),
    {ok, TotalParts, Parts} = esmpplib_encoding:split_in_parts(1, MsgEncoded, MaxLength),
    ?assertEqual(1, TotalParts),
    [Part1] = Parts,
    ?assertEqual(140, byte_size(Part1)).

encode_messages_ucs2_split_test() ->
    Msg = <<"`123456789`123456789`123456789`123456789`123456789`123456789`12345678s`">>,
    {ok, DataCoding, MaxLength} = esmpplib_encoding:get_data_coding(Msg, undefined),
    ?assertEqual(71, byte_size(Msg)),
    ?assertEqual(?ENCODING_SCHEME_UCS2, DataCoding),
    ?assertEqual(140, MaxLength),
    {ok, MsgEncoded} = esmpplib_encoding:encode(DataCoding, Msg),
    ?assertEqual(142, byte_size(MsgEncoded)),
    {ok, TotalParts, Parts} = esmpplib_encoding:split_in_parts(1, MsgEncoded, MaxLength),
    ?assertEqual(2, TotalParts),
    [Part1, Part2] = Parts,
    ?assertEqual(140, byte_size(Part1)),
    ?assertEqual(14, byte_size(Part2)).

encode_decode_gsm_test() ->
    Msg = <<"123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456|">>,
    encode_decode_helper(Msg, 160, ?ENCODING_SCHEME_MC_SPECIFIC, 160, 161).

encode_decode_ucs2_test() ->
    Msg = <<"`123456789`123456789`123456789`123456789`123456789`123456789`12345678`">>,
    encode_decode_helper(Msg, 70, ?ENCODING_SCHEME_UCS2, 140, 140).

% internals

encode_decode_helper(Msg, ExpectedMsgLength, ExpectedDataCoding, ExpectedMaxDcLength, ExpectedEncodedLength) ->
    {ok, DataCoding, MaxLength} = esmpplib_encoding:get_data_coding(Msg, undefined),
    ?assertEqual(ExpectedMsgLength, byte_size(Msg)),
    ?assertEqual(ExpectedDataCoding, DataCoding),
    ?assertEqual(ExpectedMaxDcLength, MaxLength),
    {ok, MsgEncoded} = esmpplib_encoding:encode(DataCoding, Msg),
    ?assertEqual(ExpectedEncodedLength, byte_size(MsgEncoded)),
    MsgDecoded = esmpplib_encoding:decode(DataCoding, MsgEncoded),
    ?assertEqual(ExpectedMsgLength, byte_size(MsgDecoded)),
    ?assertEqual(Msg, MsgDecoded).