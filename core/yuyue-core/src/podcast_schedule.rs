//! 到点自己出新一集 (播客开发方案 §3.4, 第二期 6): when a show's next episode is due, and on
//! which device. A show is written by one device only (`Show::device`, by default the one it was
//! made on), so two don't write the same episode; the others get the script through sync.
//!
//! A slot is a scheduled day at the show's minute, local time. One is due once it has passed and
//! no episode came after it (or shortly before: one written by hand at 6:50 serves 7:00). A slot
//! missed while the device was off is still written when it's back, but not one from long ago:
//! that would only be yesterday's news.

use crate::api::YuyueCore;
use crate::error::Result;
use crate::podcast::ShowSchedule;

const MINUTE: i64 = 60_000;
const DAY: i64 = 24 * 60 * MINUTE;
/// A missed slot is written up to this long after it.
const CATCH_UP: i64 = 20 * 60 * MINUTE;
/// An episode written up to this long before a slot serves it.
const EARLY: i64 = 2 * 60 * MINUTE;

/// 1 = Monday … 7 = Sunday, of a day counted from 1970-01-01 (a Thursday).
fn weekday(day: i64) -> u32 {
    ((day + 3).rem_euclid(7) + 1) as u32
}

/// The latest slot at or before `now_ms`, or None when the show is written only when asked.
pub fn last_slot(s: &ShowSchedule, now_ms: i64, utc_offset_minutes: i32) -> Option<i64> {
    let off = utc_offset_minutes as i64 * MINUTE;
    let local = now_ms + off;
    let today = local.div_euclid(DAY);
    (0..=7).map(|k| today - k).filter(|&d| s.days.contains(&weekday(d))).map(|d| d * DAY + s.minute as i64 * MINUTE).find(|&t| t <= local).map(|t| t - off)
}

/// The next slot after `now_ms`.
pub fn next_slot(s: &ShowSchedule, now_ms: i64, utc_offset_minutes: i32) -> Option<i64> {
    let off = utc_offset_minutes as i64 * MINUTE;
    let local = now_ms + off;
    let today = local.div_euclid(DAY);
    (0..=8).map(|k| today + k).filter(|&d| s.days.contains(&weekday(d))).map(|d| d * DAY + s.minute as i64 * MINUTE).find(|&t| t > local).map(|t| t - off)
}

/// A show whose episode is due now, and the slot it's for.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DueShow {
    pub show: String,
    pub slot_ms: i64,
}

#[uniffi::export]
impl YuyueCore {
    /// The shows this device writes whose episode is due at `now_ms`: a slot has passed (not
    /// long ago) and no episode came after it. The app writes them, once a slot.
    pub fn due_shows(&self, now_ms: i64, utc_offset_minutes: i32) -> Result<Vec<DueShow>> {
        let me = self.device_id();
        let mut out = Vec::new();
        for show in self.shows()? {
            if show.device.as_deref().is_some_and(|d| d != me) {
                continue;
            }
            let Some(slot) = last_slot(&show.schedule, now_ms, utc_offset_minutes) else { continue };
            if now_ms - slot > CATCH_UP {
                continue;
            }
            // A show made after the slot hasn't missed it.
            if show.created_at > slot {
                continue;
            }
            let latest = self.episodes(show.id.clone())?.iter().map(|e| e.at).max();
            if latest.is_some_and(|at| at >= slot - EARLY) {
                continue;
            }
            out.push(DueShow { show: show.id, slot_ms: slot });
        }
        Ok(out)
    }

    /// When the soonest of this device's shows is next due, for the app to wake up then.
    pub fn next_show_slot(&self, now_ms: i64, utc_offset_minutes: i32) -> Result<Option<i64>> {
        let me = self.device_id();
        Ok(self.shows()?.iter().filter(|s| s.device.as_deref().is_none_or(|d| d == me)).filter_map(|s| next_slot(&s.schedule, now_ms, utc_offset_minutes)).min())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-11-04 is a Wednesday. Its midnight UTC:
    const WED: i64 = 20_761 * DAY;

    #[test]
    fn weekdays() {
        assert_eq!(weekday(0), 4); // 1970-01-01, Thursday
        assert_eq!(weekday(20_761), 3);
    }

    #[test]
    fn slots_in_local_time() {
        let weekdays = ShowSchedule { days: vec![1, 2, 3, 4, 5], minute: 7 * 60 };
        let beijing = 8 * 60;
        // Wednesday 9:00 in Beijing: the last slot is 7:00 that morning.
        let now = WED + 9 * 60 * MINUTE - beijing as i64 * MINUTE;
        assert_eq!(last_slot(&weekdays, now, beijing), Some(WED + 7 * 60 * MINUTE - beijing as i64 * MINUTE));
        assert_eq!(next_slot(&weekdays, now, beijing), Some(WED + DAY + 7 * 60 * MINUTE - beijing as i64 * MINUTE));
        // Saturday 9:00: last was Friday, next is Monday.
        let sat = now + 3 * DAY;
        assert_eq!(last_slot(&weekdays, sat, beijing), Some(WED + 2 * DAY + 7 * 60 * MINUTE - beijing as i64 * MINUTE));
        assert_eq!(next_slot(&weekdays, sat, beijing), Some(WED + 5 * DAY + 7 * 60 * MINUTE - beijing as i64 * MINUTE));
        // No days: only when asked.
        let never = ShowSchedule { days: vec![], minute: 7 * 60 };
        assert_eq!(last_slot(&never, now, beijing), None);
        assert_eq!(next_slot(&never, now, beijing), None);
    }
}
