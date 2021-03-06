-module(tunnel_manager, [Config, ConnectionSemaphore]).
-export([start/0]).

start() ->
    case(dict:find(working_dir, Config)) of
        error       -> ok; % Don't change the working directory.
        {ok, false} -> ok; % Don't change the working directory.
        {ok, WorkingDir} ->
            case(file:set_cwd(WorkingDir)) of
                ok -> ok;
                {error, Error} ->
                    io:format("Could not the working dir to ~s: ~p~n", [WorkingDir, Error]),
                    erlang:exit(Error)
            end
    end,
    
    link(ConnectionSemaphore),
    
    log4erl:info("Starting server"),
    
	{ok, HostForBindingTheAdhearsionSocket} = inet_parse:address(config_get(adhearsion_listen_on)),
	{ok, HostForBindingTheAsteriskSocket}   = inet_parse:address(config_get(asterisk_listen_on)),
	
	{ok, AdhearsionServerSocket} = gen_tcp:listen(config_get(adhearsion_port),
	    [list, {packet, line}, {active, false}, {ip, HostForBindingTheAdhearsionSocket}]),
	{ok, AsteriskServerSocket}   = gen_tcp:listen(config_get(asterisk_port),
	    [list, {packet, line}, {active, false},{ip, HostForBindingTheAsteriskSocket}]),
	
	log4erl:info("Listening on ports"),
	
	Adhearsion = spawn_link(fun() -> receive_adhearsion_connection_loop(AdhearsionServerSocket) end),
    Asterisk   = spawn_link(fun() -> receive_asterisk_connection_loop(AsteriskServerSocket) end),
    
    receive
        stop ->
            log4erl:info("Received stop request");
        {'EXIT', Adhearsion, Why} ->
            log4erl:fatal("Adhearsion connection loop error! ~p", [Why]);
        {'EXIT', Asterisk, Why} ->
            log4erl:fatal("Asterisk connection loop error! ~p", [Why]);
        {'EXIT', Other, Why} ->
            log4erl:fatal("PROCESS CRASH: [~p] ~p", [Other, Why])
    end,
    
    ConnectionSemaphore ! stop,
    
    gen_tcp:close(AdhearsionServerSocket),
    gen_tcp:close(AsteriskServerSocket).

receive_asterisk_connection_loop(ServerSocket) ->
    case(gen_tcp:accept(ServerSocket)) of
        {ok, FromAsterisk} ->
            log4erl:info("Received a connection from Asterisk: ~p", [FromAsterisk]),

            ConnectionHandler = spawn(fun() -> handle_asterisk_connection(FromAsterisk) end),
            gen_tcp:controlling_process(FromAsterisk, ConnectionHandler),
            ConnectionHandler ! start,
            receive_asterisk_connection_loop(ServerSocket);
        {error, Error} ->
            log4erl:error("Got an error in the asterisk connection loop! ~p", [Error]),
            receive_asterisk_connection_loop(ServerSocket)
    end.

receive_adhearsion_connection_loop(ServerSocket) ->
	case(gen_tcp:accept(ServerSocket)) of
	    {ok, FromAdhearsion} ->
            log4erl:info("Received a connection from Adhearsion: ~p", [FromAdhearsion]),

        	ConnectionHandler = spawn(fun() -> handle_adhearsion_connection(FromAdhearsion) end),
        	gen_tcp:controlling_process(FromAdhearsion, ConnectionHandler),
        	ConnectionHandler ! start,
        	receive_adhearsion_connection_loop(ServerSocket);
        {error, Error} ->
            log4erl:error("Error in gen_tcp:accept/1 when getting an Adhearsion socket: ~p", [Error]),
            io:format("Got an error in the adhearsion connection loop! ~p", [Error]),
            receive_adhearsion_connection_loop(ServerSocket)
    end.

handle_asterisk_connection(FromAsterisk) ->
    receive start -> ok end,
    case(extract_username_and_headers_via_agi(FromAsterisk)) of
        {username, Username, headers, Headers} ->
            ConnectionSemaphore ! {tunnel_connection_request, self(), Username},
            receive
                no_socket_waiting ->
                    log4erl:warn("Asterisk AGI call came in but no matching remote Adhearsion app for user ~p", [Username]),
                    gen_tcp:send(FromAsterisk, "SET VARIABLE BRIDGE_OUTCOME \"FAILED\""),
                    gen_tcp:close(FromAsterisk);
                {found, AdhearsionPid} ->
                    gen_tcp:controlling_process(FromAsterisk, AdhearsionPid),
                    AdhearsionPid ! {bridge_request, FromAsterisk, Headers},
                    log4erl:debug("Handing control of Asterisk socket for ~s to ~p ", [Username, AdhearsionPid])
            end;
        Error ->
            log4erl:error("Encountered an error when handling the AGI request from Asterisk: ~p", [Error]),
            gen_tcp:send(FromAsterisk, "SET VARIABLE BRIDGE_OUTCOME \"FAILED\""),
            gen_tcp:close(FromAsterisk)
    end.

handle_adhearsion_connection(FromAdhearsion) ->
    receive
        start ->
            % Receive just the authentication string
            ok = inet:setopts(FromAdhearsion, [{active, once}]),
            log4erl:debug("Handling an Adhearsion connection. Expecting initial data next"),
            handle_adhearsion_connection(FromAdhearsion);
        {tcp, FromAdhearsion, InitialData} ->
            log4erl:debug("Got initial data: ~p", [InitialData]),
            case(check_authentication(InitialData)) of
        	    not_allowed ->
        	        log4erl:warn("Received an Adhearsion sandbox connection but is not allowed to connect!"),
        	        gen_tcp:send(FromAdhearsion, "authentication failed\n"),
                    gen_tcp:close(FromAdhearsion);
        	    not_found ->
        	        log4erl:warn("Received an Adhearsion sandbox connection but is not allowed to connect!"),
        	        gen_tcp:send(FromAdhearsion, "authentication failed\n"),
                    gen_tcp:close(FromAdhearsion);
        		{ok, Username} ->
        		    log4erl:info("Adhearsion request from ~s", [Username]),
        		    % {active,true} used so we can get either a protocol mismatch or socket disconnect.
        		    inet:setopts(FromAdhearsion, [{active, true}]),
        		    case(wait_for_agi_leg(Username)) of
        		        timeout ->
        		            log4erl:info("Killing sandbox socket for user ~p due to timeout", [Username]),
                            gen_tcp:close(FromAdhearsion);
                        too_many_waiting ->
                            log4erl:warn("Not allowing new sandbox connection because too many sockets are waiting"),
                            gen_tcp:send(FromAdhearsion, "wait 10\n"),
                            gen_tcp:close(FromAdhearsion);
                        protocol_error ->
                            log4erl:error("Adhearsion app sent data for some reason! Closing the socket."),
                            gen_tcp:close(FromAdhearsion);
                        socket_closed  ->
                            log4erl:info("Adhearsion app disconnected before an Asterisk AGI call came in."),
                            gen_tcp:close(FromAdhearsion);
        		        {bridge_legs, FromAsterisk, Headers} ->
        		            start_tunnel_session(Username, FromAdhearsion, FromAsterisk, Headers)
        	        end
        	end;
        {tcp_closed, FromAdhearsion} ->
            log4erl:info("Adhearsion socket closed before receiving any information");
        Error ->
            log4erl:error("Got a gen_tcp error! ~p", [Error]),
            {error, Error}
    end.

% Yay! A connection has been made. Let's now start forwarding packets back and forth.
start_tunnel_session(Username, FromAdhearsion, FromAsterisk, Headers) ->
    
    ConnectionSemaphore ! {tunnel_completed, Username},
    
    gen_tcp:send(FromAdhearsion, "authentication accepted\n"),
    gen_tcp:send(FromAsterisk, "SET VARIABLE BRIDGE_OUTCOME \"SUCCESS\""),
    
    ok = inet:setopts(FromAsterisk, [{active, once}]),
    receive {tcp, FromAsterisk, "200 result=1\n"} -> ok end,

    % The Adhearsion->AGI protocol is ridiculous. It has no delimiter.
    ok = inet:setopts(FromAdhearsion, [{active, true}, {nodelay, true}, {packet, raw}]),

    ok = inet:setopts(FromAsterisk, [{active, true}, {nodelay, true}]),
    
    % Because the Asterisk PID had to read the headers to properly service itself, we'll write them back (in reverse order)
    lists:foreach(fun(Header) ->
        gen_tcp:send(FromAdhearsion, Header)
    end, Headers),
    gen_tcp:send(FromAdhearsion, "\n"),

    log4erl:debug("Starting tunnel loop with headers ~p", [Headers]),
    
    tunnel_loop(Username, FromAdhearsion, FromAsterisk).
    
tunnel_loop(Username, FromAdhearsion, FromAsterisk) ->
    receive
        {tcp, FromAdhearsion, Line} ->
            gen_tcp:send(FromAsterisk, Line),
            tunnel_loop(Username, FromAdhearsion, FromAsterisk);
        {tcp, FromAsterisk, Line} ->
            gen_tcp:send(FromAdhearsion, Line),
            tunnel_loop(Username, FromAdhearsion, FromAsterisk);
        {tcp_closed, FromAsterisk} ->
            ConnectionSemaphore ! {tunnel_completed, Username},
            log4erl:info("Session for ~p stopped gracefully", [Username]),
            gen_tcp:close(FromAdhearsion);
        {tcp_closed, FromAdhearsion} ->
            ConnectionSemaphore ! {tunnel_completed, Username},
            log4erl:info("Session for ~p stopped gracefully", [Username]),
            gen_tcp:close(FromAsterisk);
        Error ->            
            ConnectionSemaphore ! {tunnel_completed, Username},
            log4erl:error("There was an error on one of the legs: ~p", [Error]),
            gen_tcp:close(FromAdhearsion),
            gen_tcp:close(FromAsterisk)
    end.

wait_for_agi_leg(Username) ->
    ConnectionSemaphore ! {tunnel_waiting, self(), Username},
    
    TimeoutInMilliseconds = config_get(default_adhearsion_wait_time) * 60 * 1000,
    
    receive
        {bridge_request, FromAsterisk, Buffer} ->
            {bridge_legs, FromAsterisk, Buffer};
        too_many_waiting ->
            too_many_waiting;
        {tcp_closed, _FromAdhearsion} ->
            ConnectionSemaphore ! {tunnel_completed, Username},
            socket_closed;
        {tcp, _Socket, _Data} ->
            ConnectionSemaphore ! {tunnel_completed, Username},
            protocol_error
        after TimeoutInMilliseconds ->
            % Timeout after a pre-defined number of minutes
            ConnectionSemaphore ! {tunnel_completed, Username},
            timeout
    end.

% The authentication request text must be exact 33 bytes: 32 for the MD5 and 1 for the "\n" line delimiter.
check_authentication(TextualData)  ->
    [LastCharacter|_] = lists:reverse(TextualData),
    if 
        length(TextualData) =:= 33, LastCharacter =:= 10 ->
            MD5 = chomp(TextualData),
        	% Get the username based on the MD5 Hash
        	case(username_for_md5(MD5)) of
        	    {found, Username} -> {ok, Username};
        	    not_found -> not_found
        	end;
        true -> not_allowed
    end.

extract_username_and_headers_via_agi(FromAsterisk) -> extract_username_and_headers_via_agi(FromAsterisk, []).
extract_username_and_headers_via_agi(FromAsterisk, Headers) ->
    ok = inet:setopts(FromAsterisk, [{active, once}]),
    receive
        {tcp, FromAsterisk, "\n"} ->
            % This is the blank line which ends the headers' section of the AGI protocol.
            ok = inet:setopts(FromAsterisk, [{active, once}]),
            gen_tcp:send(FromAsterisk, "GET VARIABLE SANDBOX_USERNAME"),
            receive
                {tcp, FromAsterisk, UsernameWithNewline} ->
                    case(extract_username_from_agi_variable_response(UsernameWithNewline)) of
						bad_match -> error;
						Username ->
		                    log4erl:info("Got an incoming Asterisk AGI call for username '~s'", [Username]),
		                    {username, Username, headers, Headers}
					end;
                Error ->
                    log4erl:error("Received unrecognized data when requesting SANDBOX_USERNAME: ~p", [Error]),
					error
            end;
        {tcp, FromAsterisk, HeaderLine} ->
            log4erl:debug("Asterisk header: ~s", [chomp(HeaderLine)]),
            extract_username_and_headers_via_agi(FromAsterisk, [HeaderLine|Headers]);
        _Error -> error
    end.


username_for_md5(MD5) ->
    Script = config_get(authentication_script),
    SearchResult = os:cmd(Script ++ " " ++ MD5),
    case(chomp(SearchResult)) of
        "Not found!" -> not_found;
        Username     -> {found, Username}
    end.

% Turns "200 result=1 (jicksta)\n" into "jicksta" or bad_match atom if not in the correct format.
extract_username_from_agi_variable_response(AGIResponse) ->
	Text = chomp(AGIResponse),
	Expected = "200 result=1 (",
	LastCharacter = lists:last(Text),
	case(lists:sublist(Text, length(Expected)) == Expected) of
		true ->
			case(LastCharacter =:= $)) of
				true ->
					[_|ReversedReturnValue] = lists:reverse(Text -- Expected),
					lists:reverse(ReversedReturnValue);
				false ->
					bad_match
			end;
		false -> bad_match
	end.

config_get(Key) ->
    dict:fetch(Key, Config).

chomp("") -> "";
chomp(String) ->
    case(lists:last(String) =:= 10) of
        true -> lists:sublist(String, length(String) - 1);
        false -> String
    end.

