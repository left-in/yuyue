//! 分角色 (听书开发方案 §5.1): the cast page — who has spoken so far — and the voice each of them
//! reads with. By default nobody has a voice of their own: everyone is read by the narrator's,
//! so a book sounds as it always did until the reader chooses otherwise. What's chosen is kept
//! per book in the store, so it syncs.
//!
//! Spoilers are kept out: the cast is only those who have spoken up to the section being read.

use serde_json::{Value, json};

use crate::api::{YuyueCore, lock};
use crate::error::Result;
use crate::script::{Line, same_person};

/// Someone who speaks in the book, as far as it has been read.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CastMember {
    /// The name the bubbles and the cast page use: the shortest way the book writes them.
    pub name: String,
    /// The other ways they're written (贾宝玉 for 宝玉), longest first.
    pub aliases: Vec<String>,
    /// Lines they say in the section being read, and up to the end of it.
    pub lines_here: u32,
    pub lines_so_far: u32,
    /// The one character in their circle (宝玉 玉, 黛玉 黛), and their colour (#RRGGBB): the same
    /// on the cast page and on the bubbles.
    pub avatar: String,
    pub color: String,
}

/// How one of the cast is read and shown. All defaults: the narrator's voice, the book's pace and
/// pitch, bubble on the left.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RoleVoice {
    /// A voice id (the apps' own: system, cloud or cloned); None reads with the narrator's.
    pub voice: Option<String>,
    /// On top of the book's pace: 1.0 the same.
    pub rate: f64,
    /// Semitones up or down from the voice's own: 0 the same.
    pub pitch: f64,
    /// Bubble on the right, like “me” in a chat.
    pub right: bool,
}

impl Default for RoleVoice {
    fn default() -> Self {
        RoleVoice { voice: None, rate: 1.0, pitch: 0.0, right: false }
    }
}

impl RoleVoice {
    fn from_json(v: &Value) -> RoleVoice {
        RoleVoice {
            voice: v.get("voice").and_then(Value::as_str).map(str::to_string),
            rate: v.get("rate").and_then(Value::as_f64).filter(|r| *r > 0.0).unwrap_or(1.0),
            pitch: v.get("pitch").and_then(Value::as_f64).unwrap_or(0.0),
            right: v.get("right").and_then(Value::as_bool).unwrap_or(false),
        }
    }

    fn is_default(&self) -> bool {
        self.voice.is_none() && (self.rate - 1.0).abs() < 1e-6 && self.pitch.abs() < 1e-6 && !self.right
    }
}

/// A role with its settings, for the cast page.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Role {
    pub name: String,
    pub voice: RoleVoice,
}

/// Groups the cast page counts under one name: everyone in `lines` with a name, merged when
/// they're the same person written two ways.
fn tally(per_section: &[Vec<Line>], here: usize) -> Vec<CastMember> {
    let mut members: Vec<CastMember> = Vec::new();
    for (i, ls) in per_section.iter().enumerate() {
        for l in ls {
            let Some(who) = &l.who else { continue };
            let m = match members.iter_mut().position(|m| same(&m.name, who) || m.aliases.iter().any(|a| a == who)) {
                Some(k) => &mut members[k],
                None => {
                    members.push(CastMember { name: who.clone(), aliases: Vec::new(), lines_here: 0, lines_so_far: 0, avatar: String::new(), color: String::new() });
                    members.last_mut().unwrap()
                }
            };
            if *who != m.name && !m.aliases.contains(who) {
                // The shorter one is the name; the longer one an alias.
                if who.chars().count() < m.name.chars().count() {
                    let old = std::mem::replace(&mut m.name, who.clone());
                    m.aliases.push(old);
                } else {
                    m.aliases.push(who.clone());
                }
                m.aliases.sort_by_key(|a| std::cmp::Reverse(a.chars().count()));
            }
            m.lines_so_far += 1;
            if i == here {
                m.lines_here += 1;
            }
        }
    }
    members
}

/// Not anyone to give a voice to: crowds and the unnamed (众人, 丫头, 孩子们).
fn is_group(name: &str) -> bool {
    crate::script::GROUPS.contains(&name) || name.ends_with('們') || name.ends_with('们') || ["孩子", "有人", "一个", "一個"].contains(&name)
}

/// 凤姐 and 凤姐儿 are one person.
fn same(a: &str, b: &str) -> bool {
    let trim = |s: &str| s.trim_end_matches(['儿', '兒']).to_string();
    same_person(a, b) || same_person(&trim(a), &trim(b))
}

#[uniffi::export]
impl YuyueCore {
    /// The cast up to and including `section`: who speaks there first (most lines first), then
    /// those who spoke before it. Crowds (众人, 二人) aren't anyone to give a voice to and are left
    /// out. Nobody after `section` is shown: no spoilers.
    pub fn book_cast(&self, book_id: String, section: u32) -> Result<Vec<CastMember>> {
        let n = self.manifest(&book_id)?.sections.len() as u32;
        let upto = section.min(n.saturating_sub(1));
        let mut per = Vec::with_capacity(upto as usize + 1);
        for s in 0..=upto {
            per.push(self.section_script(book_id.clone(), s).map(|x| x.lines).unwrap_or_default());
        }
        let mut cast: Vec<CastMember> = tally(&per, upto as usize).into_iter().filter(|m| !is_group(&m.name)).collect();
        let names = self.section_script(book_id.clone(), upto)?.cast;
        for m in &mut cast {
            m.avatar = avatar(&m.name, &names);
            m.color = color(&m.name).to_string();
        }
        cast.sort_by(|a, b| (b.lines_here > 0).cmp(&(a.lines_here > 0)).then(b.lines_here.cmp(&a.lines_here)).then(b.lines_so_far.cmp(&a.lines_so_far)).then(a.name.cmp(&b.name)));
        Ok(cast)
    }

    /// How each of the cast that has settings is read. Anyone not here reads with the narrator.
    pub fn book_roles(&self, book_id: String) -> Result<Vec<Role>> {
        let fields = lock(&self.store).fields(&format!("roles/book/{book_id}"))?;
        let mut roles: Vec<Role> = fields
            .iter()
            .filter(|(_, v)| !v.is_null())
            .map(|(name, v)| Role { name: name.clone(), voice: RoleVoice::from_json(v) })
            .filter(|r| !r.voice.is_default())
            .collect();
        roles.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(roles)
    }

    /// Sets how one of the cast is read; all defaults puts them back to the narrator's voice.
    pub fn set_book_role(&self, book_id: String, name: String, voice: RoleVoice) -> Result<()> {
        self.book_dir(&book_id)?;
        let value = if voice.is_default() {
            Value::Null
        } else {
            json!({ "voice": voice.voice, "rate": voice.rate, "pitch": voice.pitch, "right": voice.right })
        };
        lock(&self.store).set(&format!("roles/book/{book_id}"), &name, value)
    }

    /// Who says each sentence of a section, for the player: the cast name (as `book_cast` gives
    /// it) of the line a sentence belongs to, or None for narration and lines nobody is sure of.
    pub fn section_roles(&self, book_id: String, section: u32) -> Result<Vec<Option<String>>> {
        let n = self.sentences(book_id.clone(), section)?.len();
        let script = self.section_script(book_id, section)?;
        let mut out = vec![None; n];
        for l in &script.lines {
            let Some(who) = &l.who else { continue };
            if is_group(who) {
                continue;
            }
            // The cast page's name for them: the shortest one the script uses for the same person.
            let name = script.cast.iter().filter(|c| same(c, who)).min_by_key(|c| c.chars().count()).cloned().unwrap_or_else(|| who.clone());
            for s in l.first..=l.last {
                if let Some(slot) = out.get_mut(s as usize) {
                    *slot = Some(name.clone());
                }
            }
        }
        Ok(out)
    }
}

/// One quote for the bubbles (contract §4, setBubbles): where it is, who says it (the cast page's
/// name, or None: a grey bubble), and how they look.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BubbleLine {
    pub first: u32,
    pub last: u32,
    pub start: u32,
    pub end: u32,
    pub who: Option<String>,
    pub avatar: String,
    pub color: String,
    pub right: bool,
}

const PALETTE: [&str; 7] = ["#3E6FA8", "#B5523E", "#A87A1F", "#3E8F62", "#7A5AA6", "#A4506F", "#5E7F86"];

/// A colour of their own that never changes: from the name itself.
pub fn color(name: &str) -> &'static str {
    PALETTE[(name.chars().map(|c| c as u32).sum::<u32>() as usize) % PALETTE.len()]
}

/// The character for their circle: the last one of the name nobody else in `among` has (宝玉 玉,
/// 宝钗 钗, 黛玉 黛 as 玉 is 宝玉's), else the first.
pub fn avatar(name: &str, among: &[String]) -> String {
    // Others: not the same person written another way (林黛玉 for 黛玉).
    let others: String = among.iter().filter(|n| !same(n, name)).map(String::as_str).collect();
    let chars: Vec<char> = name.chars().collect();
    chars.iter().rev().find(|c| !others.contains(**c)).or(chars.first()).map(|c| c.to_string()).unwrap_or_else(|| "?".into())
}

#[uniffi::export]
impl YuyueCore {
    /// 气泡模式 for this book: chosen per book, synced.
    pub fn book_bubbles(&self, book_id: String) -> Result<bool> {
        Ok(lock(&self.store).get(&format!("layout/book/{book_id}"), "bubbles")?.and_then(|v| v.as_bool()).unwrap_or(false))
    }

    pub fn set_book_bubbles(&self, book_id: String, on: bool) -> Result<()> {
        self.book_dir(&book_id)?;
        lock(&self.store).set(&format!("layout/book/{book_id}"), "bubbles", json!(on))
    }

    /// The section's quotes as the reader draws them in 气泡模式.
    pub fn section_bubbles(&self, book_id: String, section: u32) -> Result<Vec<BubbleLine>> {
        let script = self.section_script(book_id.clone(), section)?;
        let roles = self.book_roles(book_id)?;
        let name_of = |who: &str| script.cast.iter().filter(|c| same(c, who)).min_by_key(|c| c.chars().count()).cloned().unwrap_or_else(|| who.to_string());
        Ok(script
            .lines
            .iter()
            .map(|l| {
                let who = l.who.as_deref().map(name_of);
                let (avatar, color, right) = match &who {
                    Some(n) => (avatar(n, &script.cast), color(n).to_string(), role_for(&roles, n).is_some_and(|r| r.right)),
                    None => ("?".into(), "#888888".into(), false),
                };
                BubbleLine { first: l.first, last: l.last, start: l.start, end: l.end, who, avatar, color, right }
            })
            .collect())
    }
}

/// The settings for `name`, looked up the way the cast page groups names.
pub fn role_for<'a>(roles: &'a [Role], name: &str) -> Option<&'a RoleVoice> {
    roles.iter().find(|r| same(&r.name, name)).map(|r| &r.voice)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::script::How;

    fn line(who: Option<&str>) -> Line {
        Line { first: 0, last: 0, start: 0, end: 0, who: who.map(str::to_string), how: How::Named }
    }

    #[test]
    fn same_person_merges_under_the_short_name() {
        let per = vec![vec![line(Some("贾宝玉")), line(Some("黛玉"))], vec![line(Some("宝玉")), line(Some("宝玉")), line(None)]];
        let cast = tally(&per, 1);
        let bao = cast.iter().find(|m| m.name == "宝玉").unwrap();
        assert_eq!(bao.aliases, vec!["贾宝玉".to_string()]);
        assert_eq!((bao.lines_here, bao.lines_so_far), (2, 3));
        let dai = cast.iter().find(|m| m.name == "黛玉").unwrap();
        assert_eq!((dai.lines_here, dai.lines_so_far), (0, 1));
    }

    #[test]
    fn roles_default_back_to_nothing() {
        let dir = std::env::temp_dir().join(format!("yuyue-roles-{}", getrandom::u64().unwrap()));
        let core = YuyueCore::open(dir.to_string_lossy().into_owned(), "test".into(), "test".into()).unwrap();
        let book = core.import_book(format!("{}/../../fixtures/books/hongloumeng.epub", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let v = RoleVoice { voice: Some("cloned.abc".into()), rate: 1.1, pitch: 2.0, right: false };
        core.set_book_role(book.id.clone(), "黛玉".into(), v.clone()).unwrap();
        assert_eq!(core.book_roles(book.id.clone()).unwrap(), vec![Role { name: "黛玉".into(), voice: v }]);
        core.set_book_role(book.id.clone(), "黛玉".into(), RoleVoice { rate: 1.0, ..Default::default() }).unwrap();
        assert!(core.book_roles(book.id.clone()).unwrap().is_empty());
        // The cast up to 第八回 has 宝玉 and 黛玉, and nobody only later in the book.
        let detail = core.book(book.id.clone()).unwrap();
        let eight = (0..detail.sections.len() as u32).find(|&i| core.sentences(book.id.clone(), i).unwrap_or_default().iter().any(|s| s.contains("比通灵金莺微露意"))).unwrap_or(8);
        let cast = core.book_cast(book.id.clone(), eight).unwrap();
        assert!(cast.iter().any(|m| m.name.ends_with("宝玉") || m.name.ends_with("寶玉")), "{cast:?}");
        let roles = core.section_roles(book.id.clone(), eight).unwrap();
        assert!(roles.iter().any(Option::is_some));
        let bubbles = core.section_bubbles(book.id.clone(), eight).unwrap();
        assert!(bubbles.iter().any(|b| b.who.is_some() && b.avatar.chars().count() == 1));
        assert!(!core.book_bubbles(book.id.clone()).unwrap());
        core.set_book_bubbles(book.id.clone(), true).unwrap();
        assert!(core.book_bubbles(book.id.clone()).unwrap());
    }

    #[test]
    fn avatars_pick_the_character_nobody_else_has() {
        let among: Vec<String> = ["宝玉", "宝钗", "黛玉"].iter().map(|s| s.to_string()).collect();
        // Both of 宝玉's are someone else's too: the first.
        assert_eq!(avatar("宝玉", &among), "宝");
        assert_eq!(avatar("宝钗", &among), "钗");
        assert_eq!(avatar("黛玉", &among), "黛");
        assert_eq!(color("黛玉"), color("黛玉"));
    }
}
