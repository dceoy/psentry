# Pull request review instructions

Review only the supplied pull request metadata and unified diff, and only for
the exact head commit named in the metadata.

Prioritize material findings in this order:

1. correctness bugs and regressions;
2. security vulnerabilities and unsafe trust-boundary changes;
3. data loss, concurrency, and failure-handling risks;
4. missing tests for behavior that is likely to break.

Avoid speculative concerns, cosmetic suggestions, and style-only feedback.
For each finding, explain the concrete impact and cite the affected file and
line when the diff supports an accurate reference. Do not invent repository
context that is not present in the supplied files.

If there are no blocking findings, say so plainly and mention any meaningful
residual testing gap in one short paragraph.

Return review-ready Markdown only. Do not include a conversational preamble,
approval/request-changes instructions, or text addressed to the automation
that invoked you.
