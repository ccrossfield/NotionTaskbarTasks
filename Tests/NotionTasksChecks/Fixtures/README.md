# Test fixtures

`query_response.json` is the raw response shape from
`POST /v1/data_sources/{id}/query` — exactly what `URLSession` hands the
decoder. It exercises every case the decoder must survive: the four real Status
options (To Do / In Progress / Blocked / Done) plus a task whose Status and
other properties are unset (`null`).

## Provenance

**Currently synthesised from the live schema**, not captured. The property
names, types, Status option names/colours and select values all match the real
`🎯 Tasks` data source that the spike confirmed on 2026-07-02 — but the exact
JSON envelope has not yet been round-tripped from Notion.

To replace it with a genuinely-captured response (one command, needs the live
token from the Keychain):

```
NOTION_TOKEN=ntn_xxx python3 spike/notion_api_spike.py \
  --dump Tests/NotionTasksCoreTests/Fixtures/query_response.json
```

The decode tests assert on specific titles/statuses, so after capturing, update
those expected values to match the real data (or point the tests at a trimmed
copy). Until then, treat a green decode test as "the decoder handles the shape",
not "the decoder handles Notion's exact bytes".
