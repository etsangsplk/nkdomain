%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%%

-module(nkdomain_types).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get_module/1, get_modules/0, get_type/1, get_types/0, register_type/2]).
-export([make_syntax/3, make_syntax_fun/3]).
-export([start_link/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args),
    lager:Type("NkDOMAIN Types "++Txt, Args)).


%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Finds a type's module
-spec get_module(nkdomain:type()) ->
    module() | undefined.

get_module(Type) when is_binary(Type) ->
    lookup({type, Type}, undefined);

get_module(Type) ->
    get_module(to_bin(Type)).


%% @doc Gets all registered modules
-spec get_modules() ->
    [module()].

get_modules() ->
    lookup(all_modules, []).


%% @doc Finds a module's type
-spec get_type(module()) ->
    nkdomain:type() | undefined.

get_type(Module) ->
    lookup({module, Module}, undefined).


%% @doc Gets all registered types
-spec get_types() ->
    [nkdomain:type()].

get_types() ->
    lookup(all_types, []).


%% @doc Gets the obj module for a type
-spec register_type(module(), nkdomain:type()) ->
    ok.

register_type(Module, Type) when is_atom(Module)->
    gen_server:call(?MODULE, {register_type, Module, to_bin(Type)}).


%% @doc
make_syntax(Module, Mandatory, Base) ->
    Fields = [binary_to_atom(list_to_binary([to_bin(Module), $., to_bin(F)]), utf8) || F <- Mandatory],
    Mandatory2 = maps:get('__mandatory', Base, []),
    Mandatory3 = Fields ++ Mandatory2,
    Base#{
        type => fun ?MODULE:make_syntax_fun/3,
        path => fun ?MODULE:make_syntax_fun/3,
        '__mandatory' => Mandatory3
    }.


%% @private
make_syntax_fun(type, Type, #{meta:=#{module:=Module}}) ->
    Type2 = to_bin(Type),
    case Module:object_get_info() of
        #{type:=Type2} ->
            ok;
        _ ->
            ?LLOG(notice, "Invalid syntax type for module ~p (~s)", [Module, Type2]),
            error
    end;

make_syntax_fun(path, Path, #{meta:=#{module:=Module}}) ->
    Path2 = to_bin(Path),
    #{type:=Type} = Module:object_get_info(),
    case lists:reverse(binary:split(Path2, <<"/">>, [global])) of
        [_Name, Types|_] ->
            case <<Type/binary, $s>> of
                Types ->
                    ok;
                _ ->
                    ?LLOG(notice, "Invalid syntax path for module ~p (~s)", [Module, Path]),
                    error
            end;
        _ ->
            ?LLOG(notice, "Invalid syntax path for module ~p (~s)", [Module, Path]),
            error
    end.



% ===================================================================
%% gen_server behaviour
%% ===================================================================

%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-record(state, {
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([]) ->
    ets:new(?MODULE, [named_table, public, {read_concurrency, true}]),
    {ok, #state{}}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({register_type, Module, Type}, _From, State) ->
    AllModules1 = get_modules(),
    AllModules2 = lists:usort([Module|AllModules1]),
    AllTypes1 = get_types(),
    AllTypes2 = lists:usort([Type|AllTypes1]),
    ets:insert(?MODULE, [
        {all_modules, AllModules2},
        {all_types, AllTypes2},
        {{type, Type}, Module},
        {{module, Module}, Type}]),
    {reply, ok, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(Info, State) ->
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->
    ok.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
lookup(Term, Empty) ->
    case ets:lookup(?MODULE, Term) of
        [] -> Empty;
        [{_, Val}] -> Val
    end.


%% @private
to_bin(Term) -> nklib_util:to_binary(Term).