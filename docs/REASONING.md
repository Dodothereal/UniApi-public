# Provider reasoning and catalog refresh

`ProviderReasoning.swift` supplies the same model-level capability contract to
the native Switcher, Codex catalog and shim request mapping. Precedence is:

1. A present `codex.model_efforts[model]` overrides everything, including when
   empty or malformed. An empty override intentionally suppresses the fallback.
2. A nonempty valid `codex.efforts` list applies across that provider.
3. The documented fallback applies only to OpenAI-format
   `deepseek/deepseek-v4.1-flash` at
   `https://api.commandcode.ai/provider/v1` (also its trailing-slash and explicit
   HTTPS port 443 spellings). An effective `proxy.direct_url` takes precedence
   over `base_url` when matching the endpoint. The fallback is `high`, `low`,
   `max`, with `high` first as the catalog default. Other models and endpoints
   do not inherit it.

CommandCode documents its [OpenAI-compatible provider endpoint](https://commandcode.ai/docs/provider).
DeepSeek documents [low/high/max effort and default high](https://api-docs.deepseek.com/guides/thinking_mode).
These are documented capabilities; discovery or a catalog entry alone does not
verify a particular gateway's inference behavior.

For this OpenAI route, a Responses request's `reasoning.effort` becomes
`reasoning_effort` on Chat Completions. Unsupported efforts fail before transport.
Omitted effort preserves the provider default. A legacy `none` also preserves
that default unless `none` is explicitly advertised; a picker showing None
therefore does not establish that the model's thinking is disabled.

## Identify the catalog producer

Source code, installed shim, active catalog producer, Codex cache and an existing
task's advertised worker roster are separate layers. A new UniApi build cannot
change an independent bridge's catalog implementation.

Older optional Web bridges construct provider rows from `codex.efforts` alone,
replacing an empty list with `none` and the description "No reasoning override".
They do not consult the native fallback or per-model overrides. Thus the native
Switcher can advertise High/Low/Max while a bridge-generated Codex cache still
shows only None. Do not broaden provider-wide efforts as a workaround: it would
advertise the DeepSeek settings for unrelated models too.

Inspect only safe provider fields, selected transport host/port, catalog
membership, and the model row's slug, efforts, default and priority. Never dump
provider documents, routing URLs containing capabilities, auth stores, model
instructions or transcripts into diagnostics.

## Apply and verify a refresh

Every generated `supported_reasoning_levels` entry must carry both string
`effort` and string `description`, including the fallback `none` entry. Codex
0.165.0's [ReasoningEffortPreset wire type](https://github.com/openai/codex/blob/rust-v0.165.0/codex-rs/protocol/src/openai_models.rs#L204)
requires the description; an omitted field rejects the catalog rather than
merely hiding its label. The native picker cache intentionally reads only the
effort, so successfully parsing that cache does not verify Codex acceptance.
Catalog tests therefore decode produced presets with required Codable strings
and reject missing, null and non-string descriptions.

1. Identify the installed producer and active route before changing anything.
   Confirm which provider document and catalog membership that producer reads.
2. If moving to native routing, install a reviewed build containing the native
   reasoning resolver and catalog builder through the guarded update flow. Use
   the journal-aware route handoff after existing work drains; do not overwrite
   another owner's configuration or restart a busy bridge. A staged preview
   build does not update the installed app or shim.
3. If retaining an optional bridge, that bridge needs its own reviewed support
   for model-level capabilities. Installing UniApi alone does not update it.
4. Refresh Codex's model catalog through the active producer. A custom
   `model_catalog_json` snapshot must also be refreshed by its owner; a file
   snapshot cannot pick up new service metadata on its own. Confirm the exact
   routed slug has `high`, `low`, `max` and default `high` in the returned/cache
   row. Preserve other models' capabilities and provider membership.
5. Recreate the affected task's worker roster after refresh. Existing advertised
   tool definitions can retain the old None-only metadata. Consumers such as
   T3 Code also need to reload their Codex model metadata; changing a saved
   effort does not refresh a catalog.

`CodexNativeCatalogTests` covers replacing a stale None-only row, preserving an
explicit empty model override, default selection, worker priority, sibling
isolation and reading the refreshed metadata through `NativeCodexModelCache`.
`ProviderReasoningTests` covers the endpoint boundary and actual shim request
mapping with a synthetic transport. These tests do not perform live inference
or install a runtime.
