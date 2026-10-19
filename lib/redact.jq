# Best-effort filtering of common credential forms, not a DLP guarantee.
gsub("(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"; "[REDACTED PRIVATE KEY]") |
gsub("\\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\\b"; "[REDACTED TOKEN]") |
gsub("(?i)\\bBearer[ \\t]+[A-Za-z0-9._~+/-]{12,}=*"; "Bearer [REDACTED]") |
gsub("(?i)(?<label>\\b(?:[A-Z0-9_]*(?:API_KEY|ACCESS_TOKEN|SECRET_KEY)|password|passwd|token|secret)[ \\t]*[:=][ \\t]*)(?<value>[^\\s,;]+)"; "\(.label)[REDACTED]")
