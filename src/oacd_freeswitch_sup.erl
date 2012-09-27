-module(oacd_freeswitch_sup).
-behavior(supervisor).

-export([init/1]).
-export([start_link/2]).

start_link(FsNode, Args) ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, {FsNode, Args}).

init({FsNode, Args}) ->
	Children = case application:get_env(cpx_managed) of
		{ok, true} ->
			[];
		_ ->
			MFA1 = {freeswitch_media_manager, start_link, [FsNode, Args]},
			Kid1 = {freeswitch_media_manager, MFA1, permanent, 1000, worker, [freeswitch_media_manager]},

			SipAuth = case proplists:get_bool(sipauth,Args) of
				sipauth -> sip_auth;
				true -> sip_auth;
				_ -> no_sip_auth
			end,
			Realms = proplists:get_value(realms,Args,[]),
			MFA2 = {freeswitch_fetch_handler, start_link, [FsNode,Args,SipAuth,Realms]},
			Kid2 = {freeswitch_fetch_handler, MFA2, permanent, 1000, worker, [freeswitch_fetch_handler]},
			[Kid1, Kid2]
	end,
	{ok, {{one_for_one, 5, 10}, Children}}.
