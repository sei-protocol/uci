"""Headless session driver for the sei-droid xreview bot.

Drives one omnigent *managed* sei-droid session through a full review
turn on behalf of a PR event, auto-resolving permission elicitations
per an injected policy, extracting the review verdict, and tearing the
session down. One invocation reviews one PR trigger exactly once.

Transport
---------
This driver speaks the REST API directly over ``httpx`` rather than the
python-client SDK, for three concrete reasons the SDK cannot cover:

* ``SessionsNamespace.create`` uploads an agent *bundle* (multipart);
  the managed flow this bot needs posts JSON
  ``{agent_id, host_type: "managed", title}`` to the same endpoint.
* The SDK exposes no session ``delete`` — teardown needs a raw
  ``DELETE /v1/sessions/{id}``.
* The SDK's typed ``Session`` snapshot omits ``pending_elicitations``;
  the driver must read the raw JSON to obtain the elicitation ids it
  resolves.

Method names here mirror the SDK (``create``/``get``/``post_event``/
``resolve_elicitation``/``delete``) so a future migration is mechanical
once the SDK grows the managed-create + delete + elicitation surface.

Authentication (unresolved — platform decision)
------------------------------------------------
How this driver proves its identity to the omnigent API
non-interactively is NOT decided here. The driver consumes a bearer
credential from the environment (``OMNIGENT_API_TOKEN`` or, preferred,
a mounted file via ``OMNIGENT_API_TOKEN_FILE`` read per invocation so a
rotated token is picked up) and sends it as ``Authorization: Bearer``.
Whether that credential is a service-account token, an OIDC-minted
token, or mTLS-fronted is for the platform lens to settle; the only
contract this code depends on is "a bearer token arrives via env/file."
"""
