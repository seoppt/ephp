-module(ephp_lib_info).
-author('manuel@altenwald.com').
-compile([warnings_as_errors]).

-include("ephp.hrl").

-export([
    init_func/0,
    init_config/0,
    init_const/0,
    phpinfo/2,
    phpversion/2,
    ini_get/3,
    set_include_path/3
]).

-spec init_func() -> ephp_func:php_function_results().

init_func() -> [
    phpinfo,
    phpversion,
    ini_get,
    set_include_path
].

-spec init_config() -> ephp_func:php_config_results().

init_config() -> [].

-spec init_const() -> ephp_func:php_const_results().

init_const() -> [
    {<<"PHP_VERSION">>, ?PHP_VERSION},
    {<<"PHP_MAJOR_VERSION">>, <<?PHP_MAJOR_VERSION>>},
    {<<"PHP_MINOR_VERSION">>, <<?PHP_MINOR_VERSION>>},
    {<<"PHP_RELEASE_VERSION">>, <<?PHP_RELEASE_VERSION>>},
    {<<"PHP_VERSION_ID">>, ?PHP_VERSION_ID},
    {<<"PHP_EXTRA_VERSION">>, ?PHP_EXTRA_VERSION},
    % Zend Thread Safety
    {<<"PHP_ZTS">>, 0},
    {<<"PHP_DEBUG">>, 0},
    % TODO: move to ephp_lib_file?
    {<<"PHP_MAXPATHLEN">>, 1024},
    {<<"PHP_OS">>, get_os()},
    {<<"PHP_OS_FAMILY">>, get_os_family()},
    {<<"PHP_SAPI">>, ephp_config:get(sapi_type, <<"cli">>)},
    {<<"PHP_EOL">>, get_os_eol()},
    % fake:
    {<<"PHP_SHLIB_SUFFIX">>, <<"so">>}
].

-spec phpinfo(context(), line()) -> undefined.

phpinfo(Context, _Line) ->
    Version = ?PHP_VERSION,
    Vsn = get_vsn(),
    BuildDate = get_build_date(),
    Release = list_to_binary(erlang:system_info(otp_release)),
    PathPHPini = filename:dirname(?PHP_INI_FILE),
    Directives = lists:foldl(fun
        ({_K,<<>>},R) -> R;
        ({K,V},R) when is_binary(K) ->
            <<R/binary, K/binary, " => ", (ephp_data:to_bin(V))/binary, "\n">>;
        (_,R) -> R
    end, <<>>, application:get_all_env(ephp)),
    Output = <<
    "phpinfo()\n"
    "PHP Version => ", Version/binary, "\n"
    "\n"
    "System => Erlang/OTP ", Release/binary, " ephp ", Vsn/binary, "\n"
    "Build Date => ", BuildDate/binary, "\n"
    "Configuration File (php.ini) Path => ", PathPHPini/binary, "\n"
    "\n"
    "Core\n"
    "\n"
    "PHP Version => ", Version/binary, "\n"
    "\n"
    "Directive => Value\n",
    Directives/binary,
    "\n"
    >>,
    ephp_context:set_output(Context, Output),
    undefined.

-spec phpversion(context(), line()) -> binary().

phpversion(_Context, _Line) ->
    ?PHP_VERSION.

-spec ini_get(context(), line(), var_value()) -> mixed().

ini_get(_Context, _Line, {_,Key}) ->
    ephp_config:get(Key).

-spec set_include_path(context(), line(), var_value()) -> binary().

set_include_path(_Context, _Line, {_,NewPath}) ->
    ephp_config:set(<<"include_path">>, NewPath),
    NewPath.

%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------

-spec get_vsn() -> binary().

get_vsn() ->
    {ok, Vsn} = application:get_key(ephp, vsn),
    list_to_binary(Vsn).

-spec get_build_date() -> binary().

get_build_date() ->
    list_to_binary(?BUILD_DATE).

-spec get_os() -> binary().

get_os() ->
    %% TODO complete the list of OS
    case os:type() of
        {unix, darwin} -> <<"Darwin">>;
        {unix, linux} -> <<"Linux">>;
        {win, nt} -> <<"WINNT">>;
        {win, _} -> <<"Windows">>
    end.

-spec get_os_family() -> binary().

get_os_family() ->
    %% TODO complete the list of OS families
    case os:type() of
        {unix, darwin} -> <<"OSX">>;
        {unix, linux} -> <<"LINUX">>;
        %% BSD
        %% Solaris
        {win, _} -> <<"WIN">>;
        {_, _} -> <<"unknown">>
    end.

-spec get_os_eol() -> binary().

get_os_eol() ->
    %% TODO change this for something more coherent :-P
    <<"\n">>.
