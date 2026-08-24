-- mod_fortress_room_ended
--
-- Notifies identity-service when a deposition room empties out, so it can
-- send the post-session exhibit-summary email (see identity-service's
-- POST /api/internal/room-ended -- see identity-service/README.md's
-- "Post-session exhibit delivery via email" section for the full flow
-- this is one piece of).
--
-- Hooks muc-room-destroyed only. An earlier version of this module also
-- hooked muc-occupant-left and called room:get_occupant_count() to detect
-- "room just went empty" itself -- that method doesn't exist on this
-- Prosody version's room object (confirmed live: every leave threw
-- "attempt to call a nil value (method 'get_occupant_count')", so the
-- webhook never fired). Turns out that whole check was redundant anyway:
-- Prosody's own core mod_muc.lua already hooks muc-occupant-left itself
-- and fires muc-room-destroyed the moment a non-persistent room (which
-- Jitsi rooms always are here -- see jitsi-meet.cfg.lua's
-- muc_room_allow_persistent = false) goes empty. So there's no "room just
-- emptied" case this module needs to detect on its own -- just react to
-- the event Prosody already raises for exactly that.
--
-- Deliberately plain http:// only, no TLS support here at all -- earlier
-- versions tried to make this work against identity-service's browser-
-- facing HTTPS port (needed there for mixed-content reasons, see that
-- service's index.ts) and hit real trouble doing it from Prosody's net.http
-- client (a per-request `insecure` flag alone still failed, since the
-- shared default client's sslctx has `verify = "peer"` baked in with no
-- per-request override; a custom client with its own `verify = "none"`
-- sslctx then hit unexplained multi-second connection timeouts on top of
-- that). Rather than keep fighting Prosody's TLS stack for a purely
-- internal, same-host call, identity-service now exposes a second, plain-
-- HTTP-only port for exactly this kind of server-to-server caller (see
-- INTERNAL_PORT in its config.ts/README) -- point this module at that one,
-- not the browser-facing HTTPS port, and none of the above applies.
--
-- Enable via docker-jitsi-meet/.env:
--   XMPP_MUC_MODULES=fortress_room_ended
--   (plus this file copied into ${CONFIG}/prosody/prosody-plugins-custom/,
--   see plugin_paths in prosody/rootfs/defaults/conf.d/jitsi-meet.cfg.lua)
-- and this module's own two options, set via Prosody's XMPP_MUC_CONFIGURATION
-- passthrough (this module loads on the MUC component, not the VirtualHost,
-- so XMPP_MUC_CONFIGURATION is the right one, not XMPP_CONFIGURATION):
--   fortress_webhook_url = "http://identity-service:4300/api/internal/room-ended"
--     -- staging: identity-service's only port, already plain HTTP
--     -- local dev: identity-service's INTERNAL_PORT (e.g. 4301), NOT its
--        HTTPS browser-facing port -- see the comment above. Also can't be
--        "localhost" -- Prosody runs in its own container/host context;
--        use host.docker.internal or, if that hangs, the literal IPv4
--        address `getent ahostsv4 host.docker.internal` resolves to
--        inside the prosody container (seen locally: the plain hostname
--        resolved to an IPv6 address that then hung rather than falling
--        back to IPv4).
--   fortress_webhook_key = "<same value as identity-service's PROSODY_WEBHOOK_KEY>"

local http = require "net.http";
local json = require "util.json";
local jid = require "util.jid";

local webhook_url = module:get_option_string("fortress_webhook_url");
local webhook_key = module:get_option_string("fortress_webhook_key");

module:hook("muc-room-destroyed", function (event)
	local room = event.room;

	if not room then
		return;
	end
	if not webhook_url or not webhook_key then
		module:log("debug", "fortress_webhook_url/fortress_webhook_key not configured -- skipping room-ended notification for %s", room.jid);
		return;
	end

	local room_node = jid.split(room.jid);

	http.request(webhook_url, {
		method = "POST";
		headers = {
			["Content-Type"] = "application/json";
			["x-fortress-prosody-key"] = webhook_key;
		};
		body = json.encode({ room = room_node });
	}, function (response_body, response_code)
		if response_code and response_code >= 200 and response_code < 300 then
			module:log("info", "Notified identity-service that room %s ended", room_node);
		else
			module:log("warn", "Failed to notify identity-service that room %s ended (HTTP %s)", room_node, tostring(response_code));
		end
	end);
end);
