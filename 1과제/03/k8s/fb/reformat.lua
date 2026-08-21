-- book 앱 logfmt access 로그 처리용 Lua 필터 2종.
--
--  1) add_duration : duration="112.663323ms" 같은 Go duration 문자열을 초 단위 숫자
--                    (duration_seconds) 로 변환한다. log_to_metrics 의 gauge 모드는
--                    value_field 가 반드시 숫자여야 하므로 메트릭 갈래 앞에서 실행한다.
--  2) reformat     : 액세스 로그를 Reference02 형식 `LEVEL {json}` 으로 재구성한다.
--                    status 로 level(INFO/WARN/ERROR)을 유도하고,
--                    액세스 로그가 아니면(=status 없음) 원본을 그대로 둔다.

-- "1.5s" / "112.663323ms" / "300µs" / "900ns" -> 초(float)
local function to_seconds(d)
    local num = tonumber(string.match(d, "^([%d%.]+)"))
    if num == nil then
        return nil
    end
    if string.find(d, "ns", 1, true) then
        return num / 1000000000
    elseif string.find(d, "ms", 1, true) then
        return num / 1000
    elseif string.find(d, "us", 1, true) or string.find(d, "\194\181s", 1, true) then
        return num / 1000000
    end
    return num
end

function add_duration(tag, timestamp, record)
    local d = record["duration"]
    if d == nil then
        return 0, timestamp, record
    end
    local sec = to_seconds(tostring(d))
    if sec == nil then
        return 0, timestamp, record
    end
    record["duration_seconds"] = sec
    return 2, timestamp, record
end

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
