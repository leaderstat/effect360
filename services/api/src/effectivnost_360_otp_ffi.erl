%% OTP application control for the API entry point.
%%
%% The `pg_types` OTP application must be LOADED before `pog` starts a
%% connection pool. `pog_ffi:update_map/3` calls
%% `application:get_key(pg_types, modules)` and crashes with
%% `{badmatch, undefined}` when the application was never loaded.
%%
%% The container starts the app with `-s effectivnost_360_api main` (see
%% services/api/Dockerfile), NOT through an OTP release, so the generated
%% `.app` file's `applications` list is never applied and `pg_types` stays
%% unloaded. Every DB query would then fail with a 503 and the pool
%% supervisor would crash-loop.
%%
%% `gleam_erlang` exposes no generic MFA-call helper, so this tiny FFI module
%% provides exactly the one primitive that is needed: start an OTP
%% application by name. It is idempotent - `application:ensure_all_started/1`
%% returns `{ok, []}` when the application is already running.

-module(effectivnost_360_otp_ffi).
-export([ensure_all_started/1]).

%% Starts the given OTP application (and its dependencies) if not already
%% running.
%%
%% The name arrives from Gleam as a UTF-8 binary, but
%% `application:ensure_all_started/1` accepts an atom only. The conversion
%% uses `binary_to_existing_atom/1` first so that a name that is not already
%% known to the atom table is rejected instead of growing it; the fallback
%% creates the atom only for a well-formed OTP application name.
%%
%% The function returns the atom `nil`: the Gleam counterpart is declared as
%% `-> Nil`, and the FFI boundary rejects any other return value.
-spec ensure_all_started(binary()) -> nil.
ensure_all_started(Application) when is_binary(Application) ->
    ensure_all_started(application_name(Application, <<"pg_types">>));
ensure_all_started(Application) when is_atom(Application) ->
    start(Application).

%% Converts the binary application name into an atom.
%%
%% `binary_to_existing_atom/1` is attempted first: every OTP application this
%% service starts (`pg_types`) is already linked into the release, so the atom
%% exists and no new atom is created. The `binary_to_atom/1` fallback is
%% restricted to names that look like an OTP application name
%% (`lowercase_start[_alnum]`) and are shorter than 256 characters.
application_name(Name, Default) when byte_size(Name) > 256 ->
    application_name(Default, Default);
application_name(<<>>, Default) ->
    application_name(Default, Default);
application_name(Name, _Default) ->
    case is_valid_application_name(Name) of
        true -> binary_to_atom(Name, utf8);
        false -> erlang:error({invalid_application_name, Name})
    end.

-spec is_valid_application_name(binary()) -> boolean().
is_valid_application_name(<<First, Rest/binary>>) when First >= $a, First =< $z ->
    is_valid_tail(Rest);
is_valid_application_name(_) ->
    false.

-spec is_valid_tail(binary()) -> boolean().
is_valid_tail(<<>>) ->
    true;
is_valid_tail(<<Char, Rest/binary>>) when
    (Char >= $a andalso Char =< $z) orelse
    (Char >= $A andalso Char =< $Z) orelse
    (Char >= $0 andalso Char =< $9) orelse
    Char =:= $_
->
    is_valid_tail(Rest);
is_valid_tail(_) ->
    false.

-spec start(atom()) -> nil.
start(Application) ->
    case application:ensure_all_started(Application) of
        {ok, _Started} -> nil;
        {error, Reason} -> erlang:error({failed_to_start_application, Application, Reason})
    end.
