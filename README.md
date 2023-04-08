esmpplib
=======

[![Build Status](https://travis-ci.com/silviucpp/esmpplib.svg?branch=master)](https://travis-ci.com/github/silviucpp/esmpplib)
[![GitHub](https://img.shields.io/github/license/silviucpp/esmpplib)](https://github.com/silviucpp/esmpplib/blob/master/LICENSE)

esmpplib is an SMPP client library for erlang.  

# Motivation

There are many erlang SMPP clients around, but after I analyzed some of those I found the following issues:

- Some libraries are no longer maintained 
- Lack of tests
- Most of them have issues when they cut the message into multiple parts. This operation is not taking into account that chars can have multiple bytes, and they end by cutting in the middle of a certain char.
- A mechanism for auto-reconnection and connection pool is not implemented.
- Are not providing an easy-to-use API without exposing the entire SMPP complexity.
- They don't provide support for secure connections (SSL).

# Features

- Connection pool.
- Support both TCP and SSL connections.
- Automatically reconnection mechanism.
- Sync and Async (with callbacks) API.
- Work with SMPP protocol version `3.4` and `5.0`.
- Support for `GSM 03.38`, `IA5 ASCII`, `LATIN1` and `UCS2/UTF-16` charsets. 
- Long messages are automatically split into multiple parts when they exceed the `data_coding` charset maximum chars limit.
- The charset (`GSM 03.38` or `UCS2`) is automatically detected if not forced in config.

# Implemented SMPP commands

The following SMPP commands are implemented currently:

- bind_transmitter
- bind_receiver
- bind_transceiver
- unbind
- enquire_link
- generic_nack
- submit_sm
- deliver_sm
- query_sm

# Quick start

### Compile

```
rebar3 compile
```

You can use the `esmpplib_connection` in case you don't want to  use the connection pool or you can define your pools inside `sys.config` :

```erlang
{esmpplib, [
    {pools, [
        {my_pool, [
            {size, 2},
            {connection_options, [
                {host, {127,0,0,1}},
                {port, 2775},
                {transport, tcp},
                {interface_version, <<"3.4">>},
                {password, <<"PWD_HERE">>},
                {system_id, <<"USERNAME_HERE">>},
                {callback_module, my_handler_module}
            ]}
        ]}
    ]}
]}
```

### Example

You can send message using the following code:

```erl
esmpplib:submit_sm(my_pool, <<"SENDER_ID">>, <<"40743XXXXX">>, <<"Hello World!">>).
```

In case you want to use the async API or to receive dlr you have to implement the `esmpplib_connection` behaviour:

```erl

-module(my_callback_handler).

-include_lib("esmpplib/include/esmpplib.hrl").

-behavior(esmpplib_connection).

on_submit_sm_response_successful(MessageRef, MessageId, NrParts) ->
    ?INFO_MSG("### on_submit_sm_response_successful -> ~p", [[MessageRef, MessageId, NrParts]]).

on_submit_sm_response_failed(MessageRef, Error) ->
    ?INFO_MSG("### on_submit_sm_response_failed -> ~p", [[MessageRef, Error]]).

on_delivery_report(MessageId, From, To, SubmitDate, DlrDate, Status, ErrorCode) ->
    ?INFO_MSG("### on_delivery_report -> ~p", [[MessageId, From, To, SubmitDate, DlrDate, Status, ErrorCode]]).
```

### Config

The supported `connection_options` configs are:

- `host` - (mandatory). The SMSCs host where the client should connect. Can be an IP (`{X,X,X,X}` or a string representing the domain).
- `port` - (mandatory). The SMSCs port.
- `transport` - What transport method should be used (`tcp` (default)  or `ssl`).
- `max_smpp_packet_size` - Maximum number of bytes a PDU can have. Default to `200000` (200 KB),
- `connection_timeout` - Connection timeout in milliseconds. Default to `5000` ms.
- `binding_response_timeout` - How many milliseconds we should wait for a binding response. Default `5000`.
- `pending_requests_timeout` - How many milliseconds we should wait for a reply to a certain request. Default to `10000`,
- `max_reconnection_time` - Maximum backoff time in milliseconds for the exponential backoff algorithm which retries to reconnect exponentially, increasing the waiting time between retries up to this limit. Default to `5000`.
- `bind_mode` - The binding mode: `transceiver` (default) , `transmitter` or `receiver`
- `system_type` - Binary string, Default to `<<"">>`. Identifies the type of ESME system requesting to bind as a transmitter with the MC.
- `interface_version` - Binary string that specify the SMPP protocol version. One of (`3.4` or `5.0`). Default to `<<"5.0">>`.
- `addr_ton` - Default to `undefined` (unknown). Indicates Type of Number of the ESME address. Used only during the biding operation.
- `addr_npi` - Default to `undefined` (unknown). Numbering Plan Indicator for ESME address. Used only during the biding operation.
- `enquire_link_time_ms` - Default to `20000`. The maximum number of ms between two `enquire_link` messages (the SMPP keep-alive mechanism). Use `0` to disable. 
- `service_type` - Binary string, Default to `<<"">>`. Can be used to indicate the SMS Application service associated with the message.
- `data_coding` - The charset used to encode the messages. Default alphabet assumed (`2#00000000`). See the `Available Encoding scheme` section below for all supported values.
- `callback_module` - (`undefined`). The application module that implements the `esmpplib_connection` behaviour, where to receive callbacks for certain events (delivery receipts or responses for async requests).
- `registered_delivery` - Allows you to specify what delivery receipts should be sent. Default to `2#00000001` (all receipts). See `Delivery Receipts` section below. 

##### Notes

- In case you are using the `esmpplib_connection` directly please note that the above settings should be sent as an erlang map not as a proplist.
- There is another `id` parameter that allows you to set a tag that's displayed in the library logs events. In case of a connection pool the pool name is set as `id`.

### Available Encoding scheme

The following encoding scheme are supported:

- `2#00000000`: MC default charset (usually GSM03.38 charset).
- `2#00000001`: IA5 (CCITT T.50)/ASCII.
- `2#00000011`: Latin 1 (ISO-8859-1).
- `2#00001000`: ISO/IEC-10646 (UCS2/UTF16-BE)

### Delivery Receipts

Using the `registered_delivery` parameter you can configure which delivery receipts to receive. The following values are supported:

- `2#00000000`: No delivery receipt
- `2#00000001`: All delivery receipts, whatever outcome.
- `2#00000010`: Only the failure delivery receipts.
- `2#00000011`: Only success delivery receipts.

# Testing

You can use `rebar3 eunit` to run the unit tests and `make ct` to run the common tests. Check `sys.config` from test folder to setup your own server.