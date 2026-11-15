# SDK session resumption: investigated, not enabled

The installed `google-antigravity==0.1.23` exposes `Agent.conversation_id` after a message exchange. Its docstring says that this identifier can be passed back through `AgentConfig.conversation_id` to resume a saved session. The public `types.SessionContinuationMode` supports `RESUME` (fail when missing), `CREATE_OR_RESUME`, and `CREATE_ONLY`. LiteRT, Local OpenAI, and Local Agent configurations pass these fields to the local harness.

Resumption also requires the original `save_dir`. `BaseLocalAgentConfig._get_or_create_save_dir()` creates a new temporary directory when it is omitted, which is the current application behavior. An identifier alone is insufficient to restore the original stored session.

This application does **not** enable persisted SDK-session resumption. Its history action explicitly starts a **new execution with the selected history as context**. It does not restore or replay saved tool-call state. Actual SDK restoration, current-policy enforcement during restoration, and the behavior of previously interrupted tool operations have not been verified; those checks are prerequisites for enabling native session resumption later.

Evidence: inspected the installed 0.1.23 package's `agent.py` (`conversation_id`), `types.py` (`SessionContinuationMode`), and `connections/local/local_connection_config.py` / `local_connection.py` (`save_dir`, `cascade_id`, and continuation-mode forwarding). Upstream source: [Antigravity SDK](https://github.com/google-antigravity/antigravity-sdk-python). Upstream main may differ from the pinned installed version.
