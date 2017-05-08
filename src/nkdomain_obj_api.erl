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

-module(nkdomain_obj_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([api/5]).

-include("nkdomain.hrl").
-include_lib("nkapi/include/nkapi.hrl").



%% ===================================================================
%% Public
%% ===================================================================


%% @doc
api('', get, #nkapi_req{data=Data}, Type, #{srv_id:=SrvId}=State) ->
    case get_id(Type, Data, State) of
        {ok, Id} ->
            case nkdomain_obj_lib:load(SrvId, Id, #{}) of
                #obj_id_ext{pid=Pid} ->
                    case nkdomain_obj:get_session(Pid) of
                        {ok, #obj_session{obj=Obj, is_enabled=Enabled}} ->
                            {ok, Obj#{'_is_enabled'=>Enabled}, State};
                        {error, Error} ->
                            {error, Error, State}
                    end;
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

api('', delete, #nkapi_req{data=Data}, Type, #{srv_id:=SrvId}=State) ->
    case get_id(Type, Data, State) of
        {ok, Id} ->
            case cmd_delete_childs(Data, SrvId, Id) of
                {ok, Num} ->
                    case nkdomain:delete(SrvId, Id) of
                        ok ->
                            {ok, #{deleted=>Num+1}, State};
                        {error, Error} ->
                            {error, Error, State}
                    end;
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

api('', update, #nkapi_req{data=Data}, Type, #{srv_id:=SrvId}=State) ->
    case get_id(Type, Data, State) of
        {ok, Id} ->
            case nkdomain:update(SrvId, Id, Data) of
                ok ->
                    {ok, #{}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

api('', enable, #nkapi_req{data=#{enable:=Enable}=Data}, Type, #{srv_id:=SrvId}=State) ->
    case get_id(Type, Data, State) of
        {ok, Id} ->
            case nkdomain:enable(SrvId, Id, Enable) of
                ok ->
                    {ok, #{}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

api('', wait_for_save, #nkapi_req{data=Data}, Type, #{srv_id:=SrvId}=State) ->
    Time = maps:get(time, Data, 5000),
    case get_id(Type, Data, State) of
        {ok, Id} ->
            case nkdomain_obj_lib:find(SrvId, Id) of
                #obj_id_ext{pid=Pid} when is_pid(Pid) ->
                    case nkdomain_obj:wait_for_save(Pid, Time) of
                        ok ->
                            {ok, #{}, State};
                        {error, Error} ->
                            {error, Error, State}
                    end;
                #obj_session{} ->
                    {error, object_not_loaded, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

api('', make_token, #nkapi_req{data=Data}, Type, #{srv_id:=SrvId}=State) ->
    Mod = nkdomain_types:get_module(Type),
    Info = Mod:object_get_info(),
    DefTTL = maps:get(default_token_ttl, Info, ?DEF_TOKEN_TTL),
    MaxTTL = maps:get(max_token_ttl, Info, ?MAX_TOKEN_TTL),
    case maps:get(ttl, Data, DefTTL) of
        TTL when TTL < MaxTTL ->
            case get_id(Type, Data, State) of
                {ok, Id} ->
                    case nkdomain_token_obj:create(SrvId, Id, TTL, #{}) of
                        {ok, ObjId, _Path, _Pid} ->
                            {ok, #{obj_id=>ObjId, ttl=>TTL}, State};
                        {error, Error} ->
                            {error, Error, State}
                    end;
                Error ->
                    Error
            end;
        _ ->
            {error, invalid_token_ttl, State}
    end;

api(_Sub, _Cmd, _Req, _Type, State) ->
    {error, not_implemented, State}.



%% ===================================================================
%% Private
%% ===================================================================

%% @doc
get_id(Type, Data, State) ->
    nkdomain_api_util:get_id(Type, id, Data, State).

%% @private
cmd_delete_childs(#{delete_childs:=true}, SrvId, Id) ->
    nkdomain_store:delete_all_childs(SrvId, Id);

cmd_delete_childs(_Data, _SrvId, _Id) ->
    {ok, 0}.
