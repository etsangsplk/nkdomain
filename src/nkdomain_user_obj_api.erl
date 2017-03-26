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

%% @doc User Object API
-module(nkdomain_user_obj_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/4]).

-include("nkdomain.hrl").

%% ===================================================================
%% API
%% ===================================================================

%% @doc
cmd('', create, #{obj_name:=Name, user:=User}, #{srv_id:=SrvId}=State) ->
    case nkdomain_util:get_service_domain(SrvId) of
        undefined ->
            {error, unknown_domain};
        Domain ->
            case nkdomain_user_obj:create(SrvId, Domain, Name, User) of
                {ok, ObjId, Path, _Pid} ->
                    {ok, #{obj_id=>ObjId, path=>Path}, State};
                {error, Error} ->
                    {error, Error, State}
            end
    end;

cmd('', login, #{id:=User}=Data, #{srv_id:=SrvId}=State) ->
    LoginMeta1 = maps:with([session_type, session_id, local, remote], State),
    LoginMeta2 = LoginMeta1#{
        password => maps:get(password, Data, <<>>),
        login_meta => maps:get(meta, Data, #{}),
        session_pid => self()
    },
    case nkdomain_user_obj:login(SrvId, User, LoginMeta2) of
        {ok, UserId, SessId, LoginMeta3} ->
            Reply = #{obj_id=>UserId, session_id=>SessId},
            State2 = case nkdomain_util:get_service_domain(SrvId) of
                undefined -> State;
                Domain -> nkdomain_util:api_add_id(?DOMAIN_DOMAIN, Domain, State)
            end,
            State3 = nkdomain_util:api_add_id(?DOMAIN_USER, UserId, State2),
            {login, Reply, UserId, LoginMeta3, State3};
        {error, Error} ->
            {error, Error, State}
    end;

%%cmd('', get_token, #{id:=User}=Data, #{srv_id:=SrvId}=State) ->
%%    Password = maps:get(password, Data, <<>>),
%%    case nkdomain_user_obj:login(SrvId, User, Password, #{}) of
%%        {ok, UserId} ->
%%            {ok, #{obj_id=>UserId}, State};
%%        {error, Error} ->
%%            {error, Error, State}
%%    end;

cmd('', find_referred, #{id:=Id}=Data, #{srv_id:=SrvId}=State) ->
    case nkdomain_util:api_getid(?DOMAIN_USER, Data, State) of
        {ok, Id} ->
            Search = nkdomain_user_obj:find_referred(SrvId, Id, Data),
            nkdomain_util:api_search(Search, State);
        Error ->
            Error
    end;

cmd('', Cmd, Data, State) ->
    nkdomain_util:api_cmd_common(?DOMAIN_USER, Cmd, Data, State);

cmd(_Sub, _Cmd, _Data, State) ->
    {error, not_implemented, State}.