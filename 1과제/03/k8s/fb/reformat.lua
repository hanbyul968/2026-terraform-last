-- book 앱 logfmt access 로그를 Reference02 형식 `LEVEL {json}` 으로 재구성한다.
-- status로 level(INFO/WARN/ERROR)을 유도하고, 접근 로그가 아니면(=status 없음) 원본 유지.
function reformat(tag, timestamp, record)
    local status = record["status"]
    if status == nil then
        return 0, timestamp, record
    end
    local level = "INFO"
    local s = tonumber(status)
    if s ~= nil then
        if s >= 500 then
            level = "ERROR"
        elseif s >= 400 then
            level = "WARN"
        else
            level = "INFO"
        end
    end
    local json = string.format('{"level":"%s","path":"%s","status":"%s","duration":"%s","method":"%s"}',
        level, record["path"] or "", tostring(status), record["duration"] or "", record["method"] or "")
    return 2, timestamp, { log = level .. " " .. json }
end
