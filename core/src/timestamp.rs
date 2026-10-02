/// Parses an RFC 3339 UTC timestamp such as `2026-10-02T19:36:32.450Z` into
/// Unix milliseconds. Agent transcripts write UTC with a `Z` suffix; anything
/// else is rejected rather than guessed.
pub fn parse_utc_ms(value: &str) -> Option<i64> {
    let (date, time) = value.strip_suffix('Z')?.split_once('T')?;

    let mut date = date.splitn(3, '-').map(|part| part.parse::<i64>().ok());
    let (year, month, day) = (date.next()??, date.next()??, date.next()??);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    let (clock, fraction) = time.split_once('.').unwrap_or((time, ""));
    let mut clock = clock.splitn(3, ':').map(|part| part.parse::<i64>().ok());
    let (hour, minute, second) = (clock.next()??, clock.next()??, clock.next()??);
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    let mut millis = 0;
    for (index, digit) in fraction.bytes().take(3).enumerate() {
        if !digit.is_ascii_digit() {
            return None;
        }
        millis += i64::from(digit - b'0') * [100, 10, 1][index];
    }

    let days = days_from_civil(year, month, day);
    Some((days * 86_400 + hour * 3600 + minute * 60 + second) * 1000 + millis)
}

/// Days since 1970-01-01 for a proleptic Gregorian date.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::parse_utc_ms;

    #[test]
    fn parses_transcript_timestamps() {
        assert_eq!(parse_utc_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc_ms("1970-01-01T00:00:01.5Z"), Some(1500));
        assert_eq!(
            parse_utc_ms("2026-10-02T19:36:32.450Z"),
            Some(1_790_969_792_450)
        );
        assert_eq!(
            parse_utc_ms("2024-02-29T12:00:00.123456Z"),
            Some(1_709_208_000_123)
        );
    }

    #[test]
    fn rejects_non_utc_or_malformed_values() {
        assert_eq!(parse_utc_ms("2026-10-02T19:36:32+09:00"), None);
        assert_eq!(parse_utc_ms("2026-13-02T19:36:32Z"), None);
        assert_eq!(parse_utc_ms("not a time"), None);
        assert_eq!(parse_utc_ms("2026-10-02T19:36:32.4x0Z"), None);
    }
}
