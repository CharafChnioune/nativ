# Meeting actions and decisions

Besides the summary, Nativ keeps an action and decision list for meetings. A list belongs to a series of meetings (for example a weekly team meeting), so each new meeting can propose new items and status changes for the items that are still open.

Columns: type (action or decision), item, owner, due, status (open, in progress, done, dropped), remark and source meeting.

## How it works

1. After a meeting summary is made, Nativ asks the local chat model for decisions, actions and updates to the open items of the linked list, using a strict JSON schema.
2. Every proposal must carry a quote of at least four words that occurs in the transcript; anything else is dropped. Updates refer to existing items as A1, A2…, and unknown references are dropped. Updates that change nothing, and new items that repeat an existing one, are dropped too.
3. Nothing is applied by itself. The **Actions** tab of a meeting shows the proposals with their quotes; accept or reject each line, or accept all.
4. Accepting a proposal for a meeting that is not linked yet creates a new list. The tab suggests an existing series when the app, title words or known speakers match.

**Check against list** runs the extraction again, for example after linking the meeting to a different list.

## Action Lists

Audio → **Action Lists** shows every list as a table. In the table you can:

- filter by status;
- change a status inline;
- edit, add or delete items.

- **Import** reads CSV (comma or semicolon) or xlsx. Columns are recognised by Dutch or English headers (Actie/Action/Item, Eigenaar/Owner, Deadline/Due, Status, Opmerking/Remark, Type). An unknown status becomes open, and the original value is kept in the remark.
- **Export** writes xlsx or CSV with the columns above.

Lists are stored in `Meeting Actions.json` in Nativ's Application Support folder.

## Limits

- The quality depends on the local model. Measured on 2026-11-11 with GLM-4.7-Flash 4-bit on two Dutch test meetings, 3 out of 3 runs gave the right result: the decision, actions with owner and due date, "klaar" as status done, and no action for a loose idea. Review the proposals anyway.
- Owners are names from the conversation or from speaker recognition; there is no link to contacts.
- Developer check: `NATIV_ACTIONS_TEST_MODEL` and `NATIV_ACTIONS_TEST_URL` (set with the `TEST_RUNNER_` prefix) run `MeetingActionsTests/testTwoMeetingsWithLocalModel` against a running local server.
