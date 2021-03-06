%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(nkdomain_service_mngr).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([register/2, get_services/0, force_update/0]).
-export([get_module/1, save_updated/2, save_removed/1]).
-export([start_link/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(TICK_TIME, 5000).

-type class() :: atom().

-type service_info() ::
    #{
        class => class(),
        status => ok | error,
        error => binary()
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Register a new service class with a callback module
-spec register(class(), module()) ->
    ok.

register(ServiceClass, Module) when is_atom(ServiceClass) ->
    {module, Module} = code:ensure_loaded(Module),
    nklib_config:put(?MODULE, {srv, ServiceClass}, Module).


%% @doc
get_services() ->
    gen_server:call(?MODULE, get_services).


force_update() ->
    abcast(force_update).
    

%% ===================================================================
%% Internal
%% ===================================================================


%% @doc Gets a service class callback module
-spec get_module(class()) ->
    module().

get_module(Class) ->
    case nklib_config:get(?MODULE, {srv, Class}, not_found) of
        not_found -> error({service_class_not_found, Class});
        Module -> Module
    end.


%% @private Called from nkdomain_obj_service
save_updated(ServiceId, Data) when is_binary(ServiceId), is_map(Data) ->
    abcast({updated, ServiceId, Data}),
    ok = riak_core_metadata:put({nkdomain, service}, ServiceId, Data).


%% @private Called from nkdomain_obj_service
save_removed(ServiceId) when is_binary(ServiceId) ->
    abcast({removed, ServiceId}),
    ok = riak_core_metadata:delete({nkdomain, service}, ServiceId).


%% @doc
-spec start_link() ->
    {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).




% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    meta_hash :: binary(),
    services = #{} :: #{nkdomain:obj_id() => {class(), service_info()}}
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([]) ->
    self() ! tick,
    {ok, #state{services=#{}}}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_services, _From, #state{services=Srvs}=State) ->
    {reply, {ok, Srvs}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({update_info, ServiceId, Info}, #state{services=Srvs}=State) ->
    Srvs1 = maps:put(ServiceId, Info, Srvs),
    {noreply, State#state{services=Srvs1}};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(tick, #state{meta_hash=Hash}=State) ->
    % lager:warning("TICK"),
    State1 = case riak_core_metadata:prefix_hash({nkdomain, service}) of
        Hash -> 
            State;
        NewHash ->
            update_services(State#state{meta_hash=NewHash})
    end,
    erlang:send_after(?TICK_TIME, self(), tick),
    {noreply, State1};

handle_info({updated, ServiceId, Data}, #state{services=Srvs}=State) ->
    Srvs1 = update_services([{ServiceId, Data}], Srvs),
    {noreply, State#state{services=Srvs1}};

handle_info({removed, ServiceId}, #state{services=Srvs}=State) ->
    Srvs1 = update_services([{ServiceId, deleted}], Srvs),
    {noreply, State#state{services=Srvs1}};

handle_info(force_update, State) ->
    State1 = update_services(State),
    {noreply, State1};

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
    


% ===================================================================
%% Internal
%% ===================================================================


%% @private
update_services(#state{services=Srvs}=State) ->
    Updates = get_meta_services(State),
    Srvs1 = update_services(Updates, Srvs),
    State#state{services=Srvs1}.


%% @private
update_services([], Srvs) ->
    Srvs;

update_services([{ServiceId, deleted}|Rest], Srvs) ->
    Srvs1 = case maps:find(ServiceId, Srvs) of
        {ok, #{class:=Class}} ->
            spawn_link(fun() -> service_call(Class, remove, [ServiceId]) end),
            maps:remove(ServiceId, Srvs);
        error ->
            Srvs
    end,
    update_services(Rest, Srvs1);

update_services([{ServiceId, #{class:=Class}=Data}|Rest], Srvs) ->
    spawn_link(
        fun() ->
            Info1 = case service_call(Class, update, [ServiceId, Data]) of
                {ok, Info0} ->
                    Info0;
                {error, Error} ->
                    #{status=>error, error=>nklib_util:to_binary(Error)};
                _ ->
                    #{status=>error, error=><<"Internal error">>}
            end,
            Info2 = Info1#{class=>Class},
            gen_server:cast(?MODULE, {update_info, ServiceId, Info2})
        end),
    update_services(Rest, Srvs).


%% @private
abcast(Msg) ->
    {ok, MyRing} = riak_core_ring_manager:get_my_ring(),
    Nodes = riak_core_ring:all_members(MyRing),
    abcast = rpc:abcast(Nodes, ?MODULE, Msg),
    ok.


%% @private
-spec service_call(class(), atom(), list()) ->
    term() | {error, binary()}.

service_call(Class, Fun, Args) ->
    try
        Module = get_module(Class),
        apply(Module, Fun, Args)
    catch
        error:{service_class_not_found, _} ->
            {error, <<"Unknown service">>};
        C:E ->
            lager:warning("Exception calling service ~p (~p): ~p:~p\n~p",
                          [Class, Fun, C, E, erlang:get_stacktrace()]),
            {error, <<"Internal error">>}
    end.


%% @private
get_meta_services(#state{services=Srvs}) ->
    riak_core_metadata:fold(
        fun
            ({Key, ['$deleted'|_]}, Acc) ->
                case maps:is_key(Key, Srvs) of
                    true -> [{Key, deleted}|Acc];
                    false -> Acc
                end;
            ({Key, [Value|_]}, Acc) ->
                [{Key, Value}|Acc]
        end,
        [],
        {nkdomain, service}).
