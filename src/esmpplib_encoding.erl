-module(esmpplib_encoding).

-include_lib("smpp_parser/src/smpp_globals.hrl").
-include("esmpplib.hrl").

% https://en.wikipedia.org/wiki/Data_Coding_Scheme
% https://messaggio.com/industry-specifications-and-standards/smpp-data-coding-scheme/

-define(GSM_ESCAPE_CHAR, 16#1B).

-define(ENCODING_SCHEME_CLASS0_FLASH_GSM_0, 16).
-define(ENCODING_SCHEME_CLASS0_FLASH_GSM_1, 240).
-define(ENCODING_SCHEME_CLASS0_FLASH_UCS2, 24).

-define(IS_DATA_CODING_GSM7(X), X == ?ENCODING_SCHEME_MC_SPECIFIC orelse X == ?ENCODING_SCHEME_CLASS0_FLASH_GSM_0 orelse X == ?ENCODING_SCHEME_CLASS0_FLASH_GSM_1).
-define(IS_DATA_CODING_UCS2(X), X == ?ENCODING_SCHEME_UCS2 orelse X == ?ENCODING_SCHEME_CLASS0_FLASH_UCS2).

-export([
    get_data_coding/2,
    split_in_parts/3,
    encode/2,
    decode/2
]).

get_data_coding(BinMessage, DataCoding) ->
    case is_basic_latin([N || <<N:1/binary>> <= BinMessage]) of
        true ->
            case DataCoding of
                undefined ->
                    {ok, ?ENCODING_SCHEME_MC_SPECIFIC, 160};
                ?ENCODING_SCHEME_MC_SPECIFIC ->
                    {ok, DataCoding, 160};
                ?ENCODING_SCHEME_LATIN_1 ->
                    {ok, DataCoding, 140};
                ?ENCODING_SCHEME_IA5_ASCII ->
                    {ok, DataCoding, 140};
                _ ->
                    {error, {unknown_data_coding, DataCoding}}
            end;
        _ ->
            {ok, ?ENCODING_SCHEME_UCS2, 140}
    end.

split_in_parts(RefNumber, Text, MaxLen) ->
    ChunkLen = max_part_length(MaxLen),
    {TotalParts, Parts0} = cut_txt(Text, MaxLen, ChunkLen, 1, [], 0),

    case TotalParts > 1 of
        true ->
            {ok, TotalParts, lists:map(fun({PartNumber, Chunk}) -> append_udh(RefNumber, TotalParts, PartNumber, Chunk) end, Parts0)};
        _ ->
            {ok, TotalParts, lists:map(fun({_PartNumber, Chunk}) -> Chunk end, Parts0)}
    end.

encode(DataCoding, Utf8) when ?IS_DATA_CODING_GSM7(DataCoding) ->
    case gsm0338:from_utf8(Utf8) of
        {valid, EncodedBin} ->
            {ok, EncodedBin};
        _ ->
            error
    end;
encode(DataCoding, Utf8) when ?IS_DATA_CODING_UCS2(DataCoding) ->
    case unicode:characters_to_binary(Utf8, utf8, {utf16, big}) of
        EncodedBin when is_binary(EncodedBin) ->
            {ok, EncodedBin};
        _ ->
            error
    end;
encode(DataCoding, Utf8) when DataCoding =:= ?ENCODING_SCHEME_LATIN_1; DataCoding =:= ?ENCODING_SCHEME_IA5_ASCII ->
    case unicode:characters_to_binary(Utf8, utf8, latin1) of
        EncodedBin when is_binary(EncodedBin) ->
            {ok, EncodedBin};
        _ ->
            error
    end;
encode(DataCoding, _Utf8) ->
    {error, {unknown_data_coding, DataCoding}}.

% note: we see clients advertising IA5 but sending gsm. not sure if this is correct
decode(DataCoding, Payload) when ?IS_DATA_CODING_GSM7(DataCoding) orelse DataCoding == ?ENCODING_SCHEME_IA5_ASCII ->
    case gsm0338:to_utf8(Payload) of
        V when is_binary(V) ->
            V;
        _ ->
            decode(?ENCODING_SCHEME_LATIN_1, Payload)
    end;
decode(DataCoding, Payload) when ?IS_DATA_CODING_UCS2(DataCoding)  ->
    case unicode:characters_to_binary(Payload, {utf16, big}, utf8) of
        EncodedBin when is_binary(EncodedBin) ->
            EncodedBin;
        _ ->
            % just fail-over as there are many clients not using big endian.
            case unicode:characters_to_binary(Payload, utf16, utf8) of
                EncodedBin2 when is_binary(EncodedBin2) ->
                    EncodedBin2;
                Error ->
                    ?ERROR_MSG("failed to decode payload: ~p from utf16 to utf8 with error:", [Payload, Error]),
                    Payload
            end
    end;
decode(?ENCODING_SCHEME_LATIN_1, Payload) ->
    case unicode:characters_to_binary(Payload, latin1, utf8) of
        EncodedBin when is_binary(EncodedBin) ->
            EncodedBin;
        Error ->
            ?ERROR_MSG("failed to decode payload: ~p from latin1 to utf8 with error:", [Payload, Error]),
            Payload
    end.

% internals

append_udh(RefNumber, TotalParts, PartNumber, Payload) ->
    <<5:8, 0:8, 3:8, RefNumber:8, TotalParts:8, PartNumber:8, Payload/binary>>.

max_part_length(160) ->
    153;
max_part_length(140) ->
    134.

is_basic_latin([]) ->
    true;
is_basic_latin([Char | Rest]) ->
    case binary:decode_unsigned(Char) of
        Val when Val < 128, Val =/= 96 ->
            is_basic_latin(Rest);
        _Val ->
            false
    end.

cut_txt(Text, MaxLength, ChunkLen, Num, Acc, AccLength) ->
    case byte_size(Text) =< MaxLength of
        true ->
            {AccLength+1, lists:reverse([{Num, Text}|Acc])};
        false ->
            {Chunk, Rest} = next_chunk(Text, ChunkLen),
            cut_txt(Rest, MaxLength, ChunkLen, Num+1, [{Num, Chunk} | Acc], AccLength+1)
    end.

next_chunk(Text, 153 = Limit) ->
    <<TmpPart:Limit/binary, TmpTail/binary>> = Text,
    case TmpPart of
        <<Rest:152/binary, ?GSM_ESCAPE_CHAR>> ->
            <<Rest:152/binary, TmpTail2/binary>> = Text,
            {Rest, TmpTail2};
        _ ->
            {TmpPart, TmpTail}
    end;
next_chunk(Text, Limit) ->
    <<TmpPart:Limit/binary, TmpTail/binary>> = Text,
    analyze_unicode(unicode:characters_to_binary(TmpPart, {utf16, big}), Text, Limit, TmpPart, TmpTail).

analyze_unicode({incomplete, _U1, _U2}, Text, Limit, _TmpPart, _TmpTail) ->
    next_chunk(Text, Limit - 2);
analyze_unicode({error, _U1, _U2}, Text, Limit, _TmpPart, _TmpTail) ->
    next_chunk(Text, Limit - 2);
analyze_unicode(_, _Text, _Limit, TmpPart, TmpTail) ->
    {TmpPart, TmpTail}.
