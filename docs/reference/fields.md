# Captured fields and relations

Generated from the core catalog by `scripts/generate`.

These readers use captured data and perform no tmux I/O. Missing capture
coverage raises an error. Nullable values and unsupported fields are distinct.

The empty-as-null column identifies tmux formats whose empty output denotes
absence. Other text retains empty strings. The `raw` reader always preserves
the captured bytes, including an empty absence marker.

The version column is the selected capture baseline; it does not establish
tested compatibility or the tmux release that introduced a field. Client
captures describe attached clients; client names are selectors, not stable IDs.

## session

| Ruby reader | Wire name | Value | Empty as null | Integer bounds | Operators | tmux format | Baseline |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `id` | `id` | `String` | no |  | `equals`, `not`, `in` | `session_id` | 3.3a |
| `name` | `name` | `String` | no |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `session_name` | 3.3a |
| `created` | `created` | `Integer` | no | -9223372036854775808..9223372036854775807 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `session_created` | 3.3a |
| `attached` | `attached` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `session_attached` | 3.3a |
| `window_count` | `windowCount` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `session_windows` | 3.3a |

| Ruby relation | Wire name | Captured result |
| --- | --- | --- |
| `windows` | `windows` | `Selection[WindowSnapshot]` |
| `window_links` | `windowLinks` | `Selection[WindowLinkSnapshot]` |
| `panes` | `panes` | `Selection[PaneSnapshot]` |
| `current_window` | `currentWindow` | `WindowSnapshot?` |

## window

| Ruby reader | Wire name | Value | Empty as null | Integer bounds | Operators | tmux format | Baseline |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `id` | `id` | `String` | no |  | `equals`, `not`, `in` | `window_id` | 3.3a |
| `name` | `name` | `String` | no |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `window_name` | 3.3a |
| `width` | `width` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `window_width` | 3.3a |
| `height` | `height` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `window_height` | 3.3a |
| `pane_count` | `paneCount` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `window_panes` | 3.3a |
| `layout` | `layout` | `String` | no |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `window_layout` | 3.3a |

| Ruby relation | Wire name | Captured result |
| --- | --- | --- |
| `panes` | `panes` | `Selection[PaneSnapshot]` |
| `window_links` | `windowLinks` | `Selection[WindowLinkSnapshot]` |
| `active_pane` | `activePane` | `PaneSnapshot?` |

## pane

| Ruby reader | Wire name | Value | Empty as null | Integer bounds | Operators | tmux format | Baseline |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `id` | `id` | `String` | no |  | `equals`, `not`, `in` | `pane_id` | 3.3a |
| `window_id` | `windowId` | `String` | no |  | `equals`, `not`, `in` | `window_id` | 3.3a |
| `index` | `index` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `pane_index` | 3.3a |
| `pid` | `pid` | `Integer` | no | 0..2147483647 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `pane_pid` | 3.3a |
| `current_command` | `currentCommand` | `String` | no |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `pane_current_command` | 3.3a |
| `current_path` | `currentPath` | `String?` | yes |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `pane_current_path` | 3.3a |
| `title` | `title` | `String` | no |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `pane_title` | 3.3a |
| `active` | `active` | `bool` | no |  | `equals`, `not`, `in` | `pane_active` | 3.3a |
| `dead` | `dead` | `bool` | no |  | `equals`, `not`, `in` | `pane_dead` | 3.3a |
| `dead_status` | `deadStatus` | `Integer?` | yes | 0..255 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `pane_dead_status` | 3.3a |
| `width` | `width` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `pane_width` | 3.3a |
| `height` | `height` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `pane_height` | 3.3a |

| Ruby relation | Wire name | Captured result |
| --- | --- | --- |
| `window` | `window` | `WindowSnapshot` |

## window_link

| Ruby reader | Wire name | Value | Empty as null | Integer bounds | Operators | tmux format | Baseline |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `session_id` | `sessionId` | `String` | no |  | `equals`, `not`, `in` | `session_id` | 3.3a |
| `window_id` | `windowId` | `String` | no |  | `equals`, `not`, `in` | `window_id` | 3.3a |
| `index` | `index` | `Integer` | no | 0..2147483647 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `window_index` | 3.3a |
| `active` | `active` | `bool` | no |  | `equals`, `not`, `in` | `window_active` | 3.3a |

| Ruby relation | Wire name | Captured result |
| --- | --- | --- |
| `session` | `session` | `SessionSnapshot` |
| `window` | `window` | `WindowSnapshot` |

## client

| Ruby reader | Wire name | Value | Empty as null | Integer bounds | Operators | tmux format | Baseline |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `name` | `name` | `String` | no |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `client_name` | 3.3a |
| `pid` | `pid` | `Integer` | no | 0..2147483647 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `client_pid` | 3.3a |
| `created` | `created` | `Integer` | no | -9223372036854775808..9223372036854775807 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `client_created` | 3.3a |
| `tty` | `tty` | `String?` | yes |  | `equals`, `not`, `in`, `contains`, `starts_with`, `ends_with` | `client_tty` | 3.3a |
| `session_id` | `sessionId` | `String?` | yes |  | `equals`, `not`, `in` | `session_id` | 3.3a |
| `width` | `width` | `Integer` | no | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `client_width` | 3.3a |
| `height` | `height` | `Integer?` | yes | 0..4294967295 | `equals`, `not`, `in`, `lt`, `lte`, `gt`, `gte` | `client_height` | 3.3a |
| `read_only` | `readOnly` | `bool` | no |  | `equals`, `not`, `in` | `client_readonly` | 3.3a |
| `utf8` | `utf8` | `bool` | no |  | `equals`, `not`, `in` | `client_utf8` | 3.3a |
| `control_mode` | `controlMode` | `bool` | no |  | `equals`, `not`, `in` | `client_control_mode` | 3.3a |

| Ruby relation | Wire name | Captured result |
| --- | --- | --- |
| `session` | `session` | `SessionSnapshot?` |
