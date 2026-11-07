//! The library database: an operation log that devices exchange to stay in step, with no
//! server in between.
//!
//! All state is a set of registers, one per (entity, field): `book/<id>` · `title`,
//! `progress/<book>/<device>` · `position`, `settings/reader` · `fontSize`. Every write is an
//! operation stamped with a hybrid logical clock; for each register the operation with the
//! highest stamp wins, whatever order operations arrive in. So any two devices that have seen
//! the same operations hold the same state.
//!
//! Only the winning operation of each register is kept: the log stays as small as the state,
//! however often reading progress is saved. Which operations a device has seen is tracked per
//! origin device (`clock`), so a sync sends only what the other side is missing.

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{CoreError, Result};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Op {
    /// The device that made the change, and its sequence number there.
    pub device: String,
    pub seq: u64,
    /// Hybrid logical clock: `{ms:013x}.{counter:04x}.{device}`. Fixed widths, so stamps
    /// compare as strings; the device makes them unique.
    pub hlc: String,
    pub entity: String,
    pub field: String,
    pub value: Value,
}

/// Seen operations: origin device → highest sequence number.
pub type Version = BTreeMap<String, u64>;

/// What one device sends another: everything the other hasn't seen.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Batch {
    /// The receiver's version the batch was made for.
    pub since: Version,
    /// The sender's version: after importing, the receiver has seen this much too.
    pub version: Version,
    pub ops: Vec<Op>,
}

pub struct Store {
    conn: Connection,
    device: String,
    /// The last stamp issued or seen: (milliseconds, counter).
    last: (u64, u32),
    now: Box<dyn Fn() -> u64 + Send>,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ops (
    device TEXT NOT NULL, seq INTEGER NOT NULL, hlc TEXT NOT NULL,
    entity TEXT NOT NULL, field TEXT NOT NULL, value TEXT NOT NULL,
    PRIMARY KEY (device, seq));
CREATE INDEX IF NOT EXISTS ops_register ON ops (entity, field);
CREATE TABLE IF NOT EXISTS registers (
    entity TEXT NOT NULL, field TEXT NOT NULL, value TEXT NOT NULL, hlc TEXT NOT NULL,
    PRIMARY KEY (entity, field));
CREATE TABLE IF NOT EXISTS clock (device TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS conflicts (
    entity TEXT NOT NULL, field TEXT NOT NULL,
    a_value TEXT NOT NULL, a_hlc TEXT NOT NULL, b_value TEXT NOT NULL, b_hlc TEXT NOT NULL,
    PRIMARY KEY (entity, field));
";

/// Two values of one register written on two devices, neither knowing of the other. The newer
/// one is the register's value; both are kept here until someone chooses. This device's own
/// record, never synced.
#[derive(Clone, Debug, PartialEq)]
pub struct Conflict {
    pub entity: String,
    pub field: String,
    /// The older and the newer, each with its stamp.
    pub older: (Value, String),
    pub newer: (Value, String),
}

/// Registers whose clashes are worth asking about: a thought written on a highlight is the
/// person's own words, and losing one silently would be losing them. The rest (where you are,
/// a colour, a setting) just take the newer.
fn watched(entity: &str, field: &str) -> bool {
    entity.starts_with("mark/") && field == "note"
}

fn wall_clock() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn new_device_id() -> String {
    let n = getrandom::u64().unwrap_or_else(|_| wall_clock() ^ (std::process::id() as u64) << 32);
    format!("{n:016x}")
}

fn parse_hlc(hlc: &str) -> Option<(u64, u32)> {
    let mut parts = hlc.split('.');
    let ms = u64::from_str_radix(parts.next()?, 16).ok()?;
    let counter = u32::from_str_radix(parts.next()?, 16).ok()?;
    Some((ms, counter))
}

impl Store {
    pub fn open(path: &Path) -> Result<Store> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        Store::init(conn, None, Box::new(wall_clock))
    }

    /// An in-memory store with a fixed device id and clock, for tests and simulations.
    pub fn in_memory(device: &str, now: Box<dyn Fn() -> u64 + Send>) -> Result<Store> {
        Store::init(Connection::open_in_memory()?, Some(device), now)
    }

    fn init(conn: Connection, device: Option<&str>, now: Box<dyn Fn() -> u64 + Send>) -> Result<Store> {
        conn.execute_batch(SCHEMA)?;
        let meta = |key: &str| -> Result<Option<String>> {
            Ok(conn.query_row("SELECT value FROM meta WHERE key = ?1", [key], |r| r.get(0)).optional()?)
        };
        let device = match meta("device")? {
            Some(d) => d,
            None => {
                let d = device.map(str::to_string).unwrap_or_else(new_device_id);
                conn.execute("INSERT INTO meta (key, value) VALUES ('device', ?1)", [&d])?;
                d
            }
        };
        let last = meta("hlc")?.as_deref().and_then(parse_hlc).unwrap_or((0, 0));
        Ok(Store { conn, device, last, now })
    }

    pub fn device(&self) -> &str {
        &self.device
    }

    /// Sets one field.
    pub fn set(&mut self, entity: &str, field: &str, value: Value) -> Result<()> {
        self.set_fields(entity, &[(field, value)])
    }

    /// Sets several fields of one entity together.
    pub fn set_fields(&mut self, entity: &str, fields: &[(&str, Value)]) -> Result<()> {
        let writes: Vec<(&str, &str, Value)> = fields.iter().map(|(f, v)| (entity, *f, v.clone())).collect();
        self.set_many(&writes)
    }

    /// Sets fields of any entities, all in one transaction: (entity, field, value).
    pub fn set_many(&mut self, writes: &[(&str, &str, Value)]) -> Result<()> {
        let tx = self.conn.transaction()?;
        let mut seq: u64 = tx
            .query_row("SELECT seq FROM clock WHERE device = ?1", [&self.device], |r| r.get::<_, i64>(0))
            .optional()?
            .unwrap_or(0) as u64;
        let mut last = self.last;
        for (entity, field, value) in writes {
            seq += 1;
            last = tick(last, (self.now)());
            let op = Op {
                device: self.device.clone(),
                seq,
                hlc: stamp(last, &self.device),
                entity: entity.to_string(),
                field: field.to_string(),
                value: value.clone(),
            };
            apply(&tx, &op)?;
            // Writing it here, after seeing both, settles it.
            tx.execute("DELETE FROM conflicts WHERE entity = ?1 AND field = ?2", params![op.entity, op.field])?;
        }
        tx.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('hlc', ?1)", [stamp(last, &self.device)])?;
        tx.commit()?;
        self.last = last;
        Ok(())
    }

    pub fn get(&self, entity: &str, field: &str) -> Result<Option<Value>> {
        let text: Option<String> = self
            .conn
            .query_row("SELECT value FROM registers WHERE entity = ?1 AND field = ?2", [entity, field], |r| r.get(0))
            .optional()?;
        Ok(text.map(|t| serde_json::from_str(&t)).transpose()?)
    }

    /// The stamp of a register's current value.
    pub fn stamp_of(&self, entity: &str, field: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT hlc FROM registers WHERE entity = ?1 AND field = ?2", [entity, field], |r| r.get(0))
            .optional()?)
    }

    pub fn fields(&self, entity: &str) -> Result<BTreeMap<String, Value>> {
        let mut stmt = self.conn.prepare_cached("SELECT field, value FROM registers WHERE entity = ?1")?;
        let rows = stmt.query_map([entity], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        let mut out = BTreeMap::new();
        for row in rows {
            let (field, value) = row?;
            out.insert(field, serde_json::from_str(&value)?);
        }
        Ok(out)
    }

    /// All entities whose name starts with `prefix` ("book/"), with their fields.
    pub fn entities(&self, prefix: &str) -> Result<BTreeMap<String, BTreeMap<String, Value>>> {
        // Names are ASCII paths; everything starting with the prefix sorts below prefix + U+FFFF.
        let upper = format!("{prefix}\u{FFFF}");
        let mut stmt = self.conn.prepare_cached(
            "SELECT entity, field, value FROM registers WHERE entity >= ?1 AND entity < ?2 ORDER BY entity",
        )?;
        let rows = stmt.query_map([prefix, upper.as_str()], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
        })?;
        let mut out: BTreeMap<String, BTreeMap<String, Value>> = BTreeMap::new();
        for row in rows {
            let (entity, field, value) = row?;
            out.entry(entity).or_default().insert(field, serde_json::from_str(&value)?);
        }
        Ok(out)
    }

    /// Clashes waiting for a choice, oldest first.
    pub fn conflicts(&self) -> Result<Vec<Conflict>> {
        let mut stmt = self.conn.prepare_cached("SELECT entity, field, a_value, a_hlc, b_value, b_hlc FROM conflicts ORDER BY b_hlc")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, String>(5)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (entity, field, a, a_hlc, b, b_hlc) = row?;
            let (a, b) = ((serde_json::from_str(&a)?, a_hlc), (serde_json::from_str(&b)?, b_hlc));
            let (older, newer) = if a.1 < b.1 { (a, b) } else { (b, a) };
            out.push(Conflict { entity, field, older, newer });
        }
        Ok(out)
    }

    pub fn version(&self) -> Result<Version> {
        let mut stmt = self.conn.prepare_cached("SELECT device, seq FROM clock")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Everything a device at version `since` hasn't seen.
    pub fn export(&self, since: &Version) -> Result<Batch> {
        let mut stmt = self.conn.prepare_cached("SELECT device, seq, hlc, entity, field, value FROM ops ORDER BY hlc")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)? as u64,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, String>(5)?,
            ))
        })?;
        let mut ops = Vec::new();
        for row in rows {
            let (device, seq, hlc, entity, field, value) = row?;
            if seq > since.get(&device).copied().unwrap_or(0) {
                ops.push(Op { device, seq, hlc, entity, field, value: serde_json::from_str(&value)? });
            }
        }
        Ok(Batch { since: since.clone(), version: self.version()?, ops })
    }

    /// Applies another device's batch. Returns how many operations changed a value.
    pub fn import(&mut self, batch: &Batch) -> Result<usize> {
        let tx = self.conn.transaction()?;
        let mut applied = 0;
        let mut last = self.last;
        let now = (self.now)();
        for op in &batch.ops {
            let Some(remote) = parse_hlc(&op.hlc) else {
                return Err(CoreError::Invalid { detail: format!("bad clock stamp {}", op.hlc) });
            };
            if !op.hlc.ends_with(&op.device) {
                return Err(CoreError::Invalid { detail: format!("stamp {} is not from {}", op.hlc, op.device) });
            }
            last = receive(last, remote, now);
            if watched(&op.entity, &op.field) {
                note_conflict(&tx, op, &batch.version)?;
            }
            if apply(&tx, op)? {
                applied += 1;
            }
        }
        // The batch held every operation the sender had beyond `since`, except ones that lost
        // to a newer value; if this store had seen at least `since`, it has now seen all the
        // sender has.
        let mine = version_of(&tx)?;
        if batch.since.iter().all(|(d, s)| mine.get(d).copied().unwrap_or(0) >= *s) {
            for (device, seq) in &batch.version {
                bump_clock(&tx, device, *seq)?;
            }
        }
        tx.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('hlc', ?1)", [stamp(last, &self.device)])?;
        tx.commit()?;
        self.last = last;
        Ok(applied)
    }
}

/// Before `op` is applied: if the register's value was written where `op`'s device hadn't seen it
/// (`sender` is that device's version) and they differ, both are kept as a clash. If it had seen
/// it, `op` came after and settles any clash there was.
fn note_conflict(conn: &Connection, op: &Op, sender: &Version) -> Result<()> {
    let current: Option<(String, String, String, i64)> = conn
        .query_row(
            "SELECT r.value, r.hlc, o.device, o.seq FROM registers r JOIN ops o ON o.entity = r.entity AND o.field = r.field AND o.hlc = r.hlc
             WHERE r.entity = ?1 AND r.field = ?2",
            params![op.entity, op.field],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    let Some((value, hlc, device, seq)) = current else { return Ok(()) };
    if hlc == op.hlc {
        return Ok(());
    }
    let seen = sender.get(&device).copied().unwrap_or(0) >= seq as u64;
    if seen {
        if op.hlc > hlc {
            conn.execute("DELETE FROM conflicts WHERE entity = ?1 AND field = ?2", params![op.entity, op.field])?;
        }
        return Ok(());
    }
    let theirs = serde_json::to_string(&op.value)?;
    let blank = |v: &str| v == "null" || v == "\"\"";
    if value == theirs || (blank(&value) && blank(&theirs)) {
        return Ok(());
    }
    conn.execute(
        "INSERT OR REPLACE INTO conflicts (entity, field, a_value, a_hlc, b_value, b_hlc) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![op.entity, op.field, value, hlc, theirs, op.hlc],
    )?;
    Ok(())
}

fn version_of(conn: &Connection) -> Result<Version> {
    let mut stmt = conn.prepare_cached("SELECT device, seq FROM clock")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn bump_clock(conn: &Connection, device: &str, seq: u64) -> Result<()> {
    conn.execute(
        "INSERT INTO clock (device, seq) VALUES (?1, ?2) ON CONFLICT (device) DO UPDATE SET seq = max(seq, excluded.seq)",
        params![device, seq as i64],
    )?;
    Ok(())
}

/// Records an operation and makes it the register's value if its stamp is the highest.
/// Returns whether it won. Operations that lose, or were already seen, are only counted.
fn apply(conn: &Connection, op: &Op) -> Result<bool> {
    bump_clock(conn, &op.device, op.seq)?;
    let value = serde_json::to_string(&op.value)?;
    let won = conn.execute(
        "INSERT INTO registers (entity, field, value, hlc) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (entity, field) DO UPDATE SET value = excluded.value, hlc = excluded.hlc
         WHERE excluded.hlc > registers.hlc",
        params![op.entity, op.field, value, op.hlc],
    )? > 0;
    if won {
        conn.execute("DELETE FROM ops WHERE entity = ?1 AND field = ?2", params![op.entity, op.field])?;
        conn.execute(
            "INSERT OR REPLACE INTO ops (device, seq, hlc, entity, field, value) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![op.device, op.seq as i64, op.hlc, op.entity, op.field, value],
        )?;
    }
    Ok(won)
}

fn stamp((ms, counter): (u64, u32), device: &str) -> String {
    format!("{ms:013x}.{counter:04x}.{device}")
}

/// The next stamp for a local change.
fn tick(last: (u64, u32), now: u64) -> (u64, u32) {
    if now > last.0 {
        (now, 0)
    } else if last.1 < 0xffff {
        (last.0, last.1 + 1)
    } else {
        (last.0 + 1, 0)
    }
}

/// The clock after seeing a remote stamp: never behind anything seen, so a later local change
/// beats every change it could have known about, even when this device's clock is slow.
fn receive(last: (u64, u32), remote: (u64, u32), now: u64) -> (u64, u32) {
    let ms = last.0.max(remote.0).max(now);
    let counter = if ms == last.0 && ms == remote.0 {
        last.1.max(remote.1)
    } else if ms == last.0 {
        last.1
    } else if ms == remote.0 {
        remote.1
    } else {
        0
    };
    (ms, counter)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn store(device: &str, clock: &Arc<AtomicU64>) -> Store {
        let c = clock.clone();
        Store::in_memory(device, Box::new(move || c.load(Ordering::SeqCst))).unwrap()
    }

    fn sync(from: &Store, to: &mut Store) {
        let batch = from.export(&to.version().unwrap()).unwrap();
        // Batches travel as JSON between devices.
        let batch: Batch = serde_json::from_str(&serde_json::to_string(&batch).unwrap()).unwrap();
        to.import(&batch).unwrap();
    }

    #[test]
    fn last_writer_wins_and_the_log_stays_small() {
        let clock = Arc::new(AtomicU64::new(1_000));
        let mut a = store("aaaaaaaaaaaaaaaa", &clock);
        a.set_fields("book/1", &[("title", json!("背影")), ("deleted", json!(false))]).unwrap();
        for page in 0..50 {
            a.set("progress/1/aaaaaaaaaaaaaaaa", "position", json!({ "section": 0, "sentence": page })).unwrap();
        }
        assert_eq!(a.get("book/1", "title").unwrap(), Some(json!("背影")));
        assert_eq!(a.get("progress/1/aaaaaaaaaaaaaaaa", "position").unwrap().unwrap()["sentence"], 49);
        let batch = a.export(&Version::new()).unwrap();
        assert_eq!(batch.ops.len(), 3, "one operation per register");
        assert_eq!(batch.version["aaaaaaaaaaaaaaaa"], 52);
        assert_eq!(a.entities("book/").unwrap().len(), 1);
        assert_eq!(a.entities("progress/1/").unwrap().len(), 1);
        assert!(a.entities("progress/2/").unwrap().is_empty());
    }

    #[test]
    fn a_slow_clock_still_wins_after_seeing_newer_changes() {
        let fast = Arc::new(AtomicU64::new(10_000));
        let slow = Arc::new(AtomicU64::new(1_000));
        let mut a = store("aaaaaaaaaaaaaaaa", &fast);
        let mut b = store("bbbbbbbbbbbbbbbb", &slow);
        a.set("settings/reader", "fontSize", json!(18)).unwrap();
        sync(&a, &mut b);
        // b's wall clock is far behind, but b has seen a's change, so b's edit comes after it.
        b.set("settings/reader", "fontSize", json!(20)).unwrap();
        sync(&b, &mut a);
        assert_eq!(a.get("settings/reader", "fontSize").unwrap(), Some(json!(20)));
        assert_eq!(b.get("settings/reader", "fontSize").unwrap(), Some(json!(20)));
    }

    #[test]
    fn importing_twice_changes_nothing() {
        let clock = Arc::new(AtomicU64::new(5));
        let mut a = store("aaaaaaaaaaaaaaaa", &clock);
        let mut b = store("bbbbbbbbbbbbbbbb", &clock);
        a.set("book/1", "title", json!("x")).unwrap();
        let batch = a.export(&Version::new()).unwrap();
        assert_eq!(b.import(&batch).unwrap(), 1);
        assert_eq!(b.import(&batch).unwrap(), 0);
        assert_eq!(b.export(&Version::new()).unwrap().ops, batch.ops);
        let mut forged = batch.clone();
        forged.ops[0].device = "cccccccccccccccc".into();
        assert!(b.import(&forged).is_err());
    }

    #[test]
    fn persists_device_and_clock() {
        let dir = std::env::temp_dir().join(format!("yuyue-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("library.db");
        let (device, stamp) = {
            let mut s = Store::open(&path).unwrap();
            s.set("book/1", "title", json!("x")).unwrap();
            (s.device().to_string(), s.stamp_of("book/1", "title").unwrap().unwrap())
        };
        assert_eq!(device.len(), 16);
        let mut s = Store::open(&path).unwrap();
        assert_eq!(s.device(), device);
        s.set("book/1", "title", json!("y")).unwrap();
        assert!(s.stamp_of("book/1", "title").unwrap().unwrap() > stamp);
        assert_eq!(s.version().unwrap()[&device], 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// xorshift64*, so the simulation is the same on every run.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    /// Devices with skewed clocks edit a few registers and sync in random pairs; afterwards
    /// a full exchange leaves every device with the same state, and every register holds the
    /// highest-stamped write anyone made to it.
    #[test]
    fn random_devices_converge() {
        for seed in 1..=20u64 {
            let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
            let n = 2 + rng.below(4) as usize;
            let clocks: Vec<Arc<AtomicU64>> = (0..n).map(|_| Arc::new(AtomicU64::new(1_000 + rng.below(5_000)))).collect();
            let mut stores: Vec<Store> = (0..n).map(|i| store(&format!("{:016x}", i + 1), &clocks[i])).collect();
            let mut best: BTreeMap<(String, String), (String, Value)> = BTreeMap::new();
            for step in 0..300 {
                let i = rng.below(n as u64) as usize;
                // Clocks move at their own pace and sometimes jump back (NTP corrections).
                let c = &clocks[i];
                let delta = rng.below(50);
                if rng.below(20) == 0 {
                    c.fetch_sub(delta.min(c.load(Ordering::SeqCst)), Ordering::SeqCst);
                } else {
                    c.fetch_add(delta, Ordering::SeqCst);
                }
                if rng.below(3) == 0 {
                    let j = rng.below(n as u64) as usize;
                    if i != j {
                        let (from, to) = if i < j {
                            let (l, r) = stores.split_at_mut(j);
                            (&l[i], &mut r[0])
                        } else {
                            let (l, r) = stores.split_at_mut(i);
                            (&r[0], &mut l[j])
                        };
                        sync(from, to);
                    }
                    continue;
                }
                let entity = format!("e{}", rng.below(4));
                let field = format!("f{}", rng.below(3));
                let value = json!(format!("{seed}-{step}"));
                stores[i].set(&entity, &field, value.clone()).unwrap();
                let hlc = stores[i].stamp_of(&entity, &field).unwrap().unwrap();
                // A local write always wins on its own device.
                assert_eq!(stores[i].get(&entity, &field).unwrap(), Some(value.clone()));
                let slot = best.entry((entity, field)).or_insert((String::new(), Value::Null));
                if hlc > slot.0 {
                    *slot = (hlc, value);
                }
            }
            // Two rounds of everyone with everyone (a ring would do too).
            for _ in 0..2 {
                for i in 0..n {
                    for j in 0..n {
                        if i == j {
                            continue;
                        }
                        let batch = stores[i].export(&stores[j].version().unwrap()).unwrap();
                        stores[j].import(&batch).unwrap();
                    }
                }
            }
            let state = stores[0].entities("e").unwrap();
            for s in &stores[1..] {
                assert_eq!(s.entities("e").unwrap(), state, "seed {seed}");
                assert_eq!(s.version().unwrap(), stores[0].version().unwrap(), "seed {seed}");
            }
            for ((entity, field), (_, value)) in &best {
                assert_eq!(&state[entity][field], value, "seed {seed} {entity}.{field}");
            }
            // Nothing left to send.
            for i in 0..n {
                for j in 0..n {
                    assert!(stores[i].export(&stores[j].version().unwrap()).unwrap().ops.is_empty(), "seed {seed}");
                }
            }
        }
    }
}
