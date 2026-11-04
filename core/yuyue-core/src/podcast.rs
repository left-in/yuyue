//! 播客 (AI 电台, docs/播客开发方案.md): a show the reader sets up, written by the model they
//! chose for 书伴 and read aloud by 语阅. This file is the part every platform shares and that
//! never goes online:
//!
//! - the shows, kept in the sync log (`show/<id>`), and each episode (`episode/<id>`);
//! - the prompts for each step, the same on every platform;
//! - checking what the model hands back, and turning a script into a book: one section, a
//!   sentence a line, each line saying who speaks it and which article it came from, so the
//!   reader, the player and 笔记 need nothing new for it.
//!
//! The apps download (`feed`), call the model, and run the steps in order, saving after each.
//!
//! Registers:
//! - `show/<id>` · `name` / `sources` / `schedule` / `minutes` / `form` / `hosts` / `language` /
//!   `brief` / `avoid` / `device` / `createdAt` / `deleted`
//! - `episode/<book id>` · `show` / `date` / `title` / `summary` / `articles` / `at` /
//!   `heard`
//!
//! 用过的文章 (which articles a show has told) stay on the device that writes the show: they're
//! never in the log, so they don't sync.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::{YuyueCore, lock, now_ms};
use crate::book::{self, Format, Manifest, SectionInfo};
use crate::epub::{Kind, TocEntry};
use crate::dom::{self, Element, Node};
use crate::error::{CoreError, Result};
use crate::i18n::tr;
use crate::normalize::{self, Context, Link};
use crate::text::{self, Stats};

// ---------------------------------------------------------------------------------------------
// Shows

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum ShowForm {
    /// 单人播报.
    Solo,
    /// 两人对谈.
    Duo,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    /// RSS or Atom.
    Feed,
    /// Hacker News: `address` is `top`, `best`, `new`, `ask` or `show`.
    HackerNews,
    /// A page looked at for changes.
    Page,
    /// 这周的划线和想法.
    Highlights,
    /// 生词本.
    Words,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ShowSource {
    pub kind: SourceKind,
    /// The feed's or page's URL; the Hacker News list; empty for 语阅's own.
    pub address: String,
    /// What the reader calls it ("少数派").
    pub name: String,
    /// 多一点少一点: 1 to 5.
    pub weight: u8,
    /// At most this many new items a time.
    pub limit: u32,
    pub paused: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ShowHost {
    /// "小林".
    pub name: String,
    /// One line about who they are ("做产品的，好奇心重，爱打比方").
    pub about: String,
    /// The voice on this device; voices differ between devices, so it's chosen on each.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice: Option<String>,
}

/// When a new episode comes: on these weekdays (1 = Monday … 7 = Sunday) at this minute of the
/// day, local time. No days: only when asked.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ShowSchedule {
    pub days: Vec<u32>,
    pub minute: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Show {
    pub id: String,
    pub name: String,
    pub sources: Vec<ShowSource>,
    pub schedule: ShowSchedule,
    /// About how long an episode is: 5, 10 or 20.
    pub minutes: u32,
    pub form: ShowForm,
    /// One for 单人, two for 对谈.
    pub hosts: Vec<ShowHost>,
    /// The episodes' language ("zh-CN", "en"), whatever the sources are in.
    pub language: String,
    /// 想多听什么、少听什么, a line to the editor.
    pub brief: String,
    /// Words that keep an article out.
    pub avoid: Vec<String>,
    /// The device that writes it; only that one does, so two don't write the same episode.
    pub device: Option<String>,
    pub created_at: i64,
}

/// A show as the reader sets it up; `id` is made by the core.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ShowDraft {
    pub name: String,
    pub sources: Vec<ShowSource>,
    pub schedule: ShowSchedule,
    pub minutes: u32,
    pub form: ShowForm,
    pub hosts: Vec<ShowHost>,
    pub language: String,
    pub brief: String,
    pub avoid: Vec<String>,
    pub device: Option<String>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Episode {
    /// The book the script is in.
    pub book: String,
    pub show: String,
    /// "2026-11-01", the day it is for.
    pub date: String,
    pub title: String,
    pub summary: String,
    /// The articles it tells, in the order it tells them.
    pub articles: Vec<ScriptArticle>,
    /// When it was written (ms).
    pub at: i64,
    /// 听完了.
    pub heard: bool,
}

#[uniffi::export]
impl YuyueCore {
    /// The shows, oldest first.
    pub fn shows(&self) -> Result<Vec<Show>> {
        let all = lock(&self.store).entities("show/")?;
        let mut out: Vec<Show> = all
            .into_iter()
            .filter(|(_, f)| f.get("deleted") != Some(&json!(true)))
            .filter_map(|(e, f)| show_from(e.strip_prefix("show/")?, &f))
            .collect();
        out.sort_by_key(|s| s.created_at);
        Ok(out)
    }

    pub fn show(&self, id: String) -> Result<Show> {
        let f = lock(&self.store).fields(&format!("show/{id}"))?;
        if f.get("deleted") == Some(&json!(true)) {
            return Err(CoreError::not_found("show"));
        }
        show_from(&id, &f).ok_or_else(|| CoreError::not_found("show"))
    }

    /// Makes a show. The device that writes it defaults to this one.
    pub fn add_show(&self, draft: ShowDraft) -> Result<Show> {
        check_draft(&draft)?;
        let id = new_id();
        let now = now_ms();
        let device = draft.device.clone().unwrap_or_else(|| self.device_id());
        let mut fields = draft_fields(&draft);
        fields.push(("device", json!(device)));
        fields.push(("createdAt", json!(now)));
        lock(&self.store).set_fields(&format!("show/{id}"), &fields)?;
        self.show(id)
    }

    /// Changes a show; only the fields that differ are written, so two devices changing two
    /// things don't undo each other.
    pub fn update_show(&self, id: String, draft: ShowDraft) -> Result<Show> {
        check_draft(&draft)?;
        let entity = format!("show/{id}");
        let mut store = lock(&self.store);
        let old = store.fields(&entity)?;
        if old.is_empty() || old.get("deleted") == Some(&json!(true)) {
            return Err(CoreError::not_found("show"));
        }
        let mut fields = draft_fields(&draft);
        if let Some(d) = &draft.device {
            fields.push(("device", json!(d)));
        }
        let changed: Vec<(&str, Value)> = fields.into_iter().filter(|(k, v)| old.get(*k) != Some(v)).collect();
        if !changed.is_empty() {
            store.set_fields(&entity, &changed)?;
        }
        drop(store);
        self.show(id)
    }

    /// Removes a show; its episodes stay until they're removed from the shelf.
    pub fn remove_show(&self, id: String) -> Result<()> {
        lock(&self.store).set(&format!("show/{id}"), "deleted", json!(true))
    }

    /// A show's episodes, the newest first.
    pub fn episodes(&self, show: String) -> Result<Vec<Episode>> {
        let all = lock(&self.store).entities("episode/")?;
        let mut out: Vec<Episode> = all
            .into_iter()
            .filter(|(_, f)| f.get("show").and_then(Value::as_str) == Some(show.as_str()))
            .filter(|(_, f)| !gone(f))
            .filter_map(|(e, f)| episode_from(e.strip_prefix("episode/")?, &f))
            .collect();
        out.sort_by(|a, b| b.date.cmp(&a.date).then(b.at.cmp(&a.at)));
        Ok(out)
    }

    /// Every show's episodes, the newest first: 最新.
    pub fn latest_episodes(&self, limit: u32) -> Result<Vec<Episode>> {
        let live: HashSet<String> = self.shows()?.into_iter().map(|s| s.id).collect();
        let all = lock(&self.store).entities("episode/")?;
        let mut out: Vec<Episode> = all
            .into_iter()
            .filter(|(_, f)| !gone(f))
            .filter_map(|(e, f)| episode_from(e.strip_prefix("episode/")?, &f))
            .filter(|e| live.contains(&e.show))
            .collect();
        out.sort_by_key(|e| std::cmp::Reverse(e.at));
        out.truncate(limit as usize);
        Ok(out)
    }

    /// 听过的节目保留 30 天 (U6): episodes heard and written at least `older_than_ms` ago go —
    /// off the list and off the shelf, as 删书 does, so the files follow once `purge_deleted`
    /// runs. One with a highlight, a thought or a bookmark in it stays: the reader kept something.
    /// Returns how many went.
    pub fn prune_heard_episodes(&self, older_than_ms: i64) -> Result<u32> {
        let cutoff = now_ms() - older_than_ms;
        let all = lock(&self.store).entities("episode/")?;
        let mut gone_now = 0;
        for (e, f) in all {
            if gone(&f) {
                continue;
            }
            let Some(ep) = e.strip_prefix("episode/").and_then(|id| episode_from(id, &f)) else { continue };
            if !ep.heard || ep.at > cutoff {
                continue;
            }
            if !self.marks(ep.book.clone())?.is_empty() || !self.bookmarks(ep.book.clone())?.is_empty() {
                continue;
            }
            // The book may be gone already (removed by hand); the episode goes all the same.
            let _ = self.delete_book(ep.book.clone());
            lock(&self.store).set(&e, "deleted", json!(true))?;
            gone_now += 1;
        }
        Ok(gone_now)
    }

    /// The episode a book is, if it is one: the player asks, to give each host their voice.
    pub fn episode(&self, book: String) -> Result<Option<Episode>> {
        let f = lock(&self.store).fields(&format!("episode/{book}"))?;
        Ok(episode_from(&book, &f))
    }

    pub fn set_episode_heard(&self, book: String, heard: bool) -> Result<()> {
        lock(&self.store).set(&format!("episode/{book}"), "heard", json!(heard))
    }

    /// Saves a checked script as an episode of `show`: a book on the shelf with the script as
    /// its one section, and the episode's register. The same script makes the same book, so
    /// saving twice gives one episode.
    pub fn save_episode(&self, show: String, date: String, script: EpisodeScript) -> Result<Episode> {
        let s = self.show(show.clone())?;
        let bytes = serde_json::to_vec(&json!({ "show": show, "date": date, "script": script_json(&script) }))?;
        let id = book::book_id(&bytes);
        let manifest = book::build_into(&self.books_dir, &id, |tmp| build_episode(tmp, &id, &s, &date, &script, &bytes))?;
        lock(&self.manifests).insert(id.clone(), std::sync::Arc::new(manifest.clone()));
        self.record_import(&manifest)?;
        let now = now_ms();
        let articles = serde_json::to_value(script.articles.iter().map(article_json).collect::<Vec<_>>())?;
        let fields = vec![
            ("show", json!(show)),
            ("date", json!(date)),
            ("title", json!(script.title)),
            ("summary", json!(script.summary)),
            ("articles", articles),
            ("at", json!(now)),
        ];
        lock(&self.store).set_fields(&format!("episode/{id}"), &fields)?;
        let f = lock(&self.store).fields(&format!("episode/{id}"))?;
        episode_from(&id, &f).ok_or_else(|| CoreError::not_found("episode"))
    }

    /// The articles this device has already told in `show`, by `article_key`.
    pub fn told_articles(&self, show: String) -> Result<Vec<String>> {
        let path = self.told_path(&show)?;
        Ok(fs::read_to_string(path).ok().and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()).unwrap_or_default())
    }

    /// Notes articles as told, so the next episode leaves them out. The last 5000 are kept.
    pub fn mark_told(&self, show: String, keys: Vec<String>) -> Result<()> {
        let mut told = self.told_articles(show.clone())?;
        let have: HashSet<String> = told.iter().cloned().collect();
        told.extend(keys.into_iter().filter(|k| !have.contains(k)));
        let excess = told.len().saturating_sub(5000);
        told.drain(..excess);
        let path = self.told_path(&show)?;
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(path, serde_json::to_string(&told)?)?;
        Ok(())
    }
}

impl YuyueCore {
    fn told_path(&self, show: &str) -> Result<std::path::PathBuf> {
        if show.is_empty() || !show.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(CoreError::not_found("show"));
        }
        let root = self.books_dir.parent().unwrap_or(&self.books_dir);
        Ok(root.join("podcast").join(format!("told-{show}.json")))
    }
}

fn new_id() -> String {
    let n = getrandom::u64().unwrap_or_else(|_| now_ms() as u64 ^ std::process::id() as u64);
    format!("{n:016x}")
}

fn check_draft(d: &ShowDraft) -> Result<()> {
    let bad = |zh: &str, en: &str| Err(CoreError::Invalid { detail: tr(zh, en) });
    if d.name.trim().is_empty() {
        return bad("节目要有个名字", "The show needs a name");
    }
    let want = match d.form {
        ShowForm::Solo => 1,
        ShowForm::Duo => 2,
    };
    if d.hosts.len() != want || d.hosts.iter().any(|h| h.name.trim().is_empty()) {
        return bad("主持人的人数和形式对不上", "The hosts don't match the form");
    }
    if d.hosts.len() == 2 && d.hosts[0].name.trim() == d.hosts[1].name.trim() {
        return bad("两位主持人要用不同的名字", "The two hosts need different names");
    }
    if d.schedule.days.iter().any(|x| !(1..=7).contains(x)) || d.schedule.minute >= 24 * 60 {
        return bad("出新一集的时间不对", "The schedule isn't valid");
    }
    if !(1..=60).contains(&d.minutes) {
        return bad("一集的长度不对", "The length isn't valid");
    }
    Ok(())
}

fn draft_fields(d: &ShowDraft) -> Vec<(&'static str, Value)> {
    let mut days = d.schedule.days.clone();
    days.sort_unstable();
    days.dedup();
    let sources: Vec<ShowSource> = d
        .sources
        .iter()
        .map(|s| ShowSource { weight: s.weight.clamp(1, 5), limit: s.limit.clamp(1, 50), name: s.name.trim().to_string(), address: s.address.trim().to_string(), ..s.clone() })
        .collect();
    let hosts: Vec<ShowHost> = d.hosts.iter().map(|h| ShowHost { name: h.name.trim().to_string(), about: h.about.trim().to_string(), voice: None }).collect();
    let avoid: Vec<String> = d.avoid.iter().map(|w| w.trim().to_string()).filter(|w| !w.is_empty()).collect();
    vec![
        ("name", json!(d.name.trim())),
        ("sources", json!(sources)),
        ("schedule", json!({ "days": days, "minute": d.schedule.minute })),
        ("minutes", json!(d.minutes)),
        ("form", json!(d.form)),
        ("hosts", json!(hosts)),
        ("language", json!(d.language.trim())),
        ("brief", json!(d.brief.trim())),
        ("avoid", json!(avoid)),
    ]
}

fn show_from(id: &str, f: &BTreeMap<String, Value>) -> Option<Show> {
    let text = |k: &str| f.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
    fn parse<T: serde::de::DeserializeOwned>(f: &BTreeMap<String, Value>, k: &str) -> Option<T> {
        f.get(k).cloned().and_then(|v| serde_json::from_value(v).ok())
    }
    Some(Show {
        id: id.to_string(),
        name: f.get("name")?.as_str()?.to_string(),
        sources: parse(f, "sources").unwrap_or_default(),
        schedule: parse(f, "schedule").unwrap_or(ShowSchedule { days: Vec::new(), minute: 7 * 60 }),
        minutes: f.get("minutes").and_then(Value::as_u64).unwrap_or(10) as u32,
        form: parse(f, "form").unwrap_or(ShowForm::Duo),
        hosts: parse(f, "hosts").unwrap_or_default(),
        language: text("language"),
        brief: text("brief"),
        avoid: parse(f, "avoid").unwrap_or_default(),
        device: f.get("device").and_then(Value::as_str).map(str::to_string),
        created_at: f.get("createdAt").and_then(Value::as_i64).unwrap_or(0),
    })
}

fn episode_from(id: &str, f: &BTreeMap<String, Value>) -> Option<Episode> {
    let text = |k: &str| f.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
    let articles: Vec<ArticleJson> = f.get("articles").cloned().and_then(|v| serde_json::from_value(v).ok()).unwrap_or_default();
    Some(Episode {
        book: id.to_string(),
        show: f.get("show")?.as_str()?.to_string(),
        date: text("date"),
        title: text("title"),
        summary: text("summary"),
        articles: articles.into_iter().map(|a| ScriptArticle { title: a.title, url: a.url, source: a.source }).collect(),
        at: f.get("at").and_then(Value::as_i64).unwrap_or(0),
        heard: f.get("heard") == Some(&json!(true)),
    })
}

// ---------------------------------------------------------------------------------------------
// Prompts (docs/播客开发方案.md §3.3). Written here so every platform asks the same.

/// An article the editor may pick from.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Candidate {
    /// Where it is in the list the app keeps; the model answers with these.
    pub index: u32,
    pub title: String,
    /// "少数派", "Hacker News · 412 条评论".
    pub source: String,
    pub weight: u8,
}

/// What to send the model: a system prompt and the message.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Prompt {
    pub system: String,
    pub user: String,
}

/// Step 3, 挑选: from the titles alone, which articles the episode tells, in order.
#[uniffi::export]
pub fn pick_prompt(show: Show, candidates: Vec<Candidate>, count: u32) -> Prompt {
    let lang = language_name(&show.language);
    let mut list = String::new();
    for c in &candidates {
        list.push_str(&format!("{}. [{}] {}（{}，权重 {}）\n", c.index, c.source, c.title, c.source, c.weight));
    }
    let avoid = if show.avoid.is_empty() { "无".to_string() } else { show.avoid.join("、") };
    let system = format!(
        "你是一档个人播客的编辑。节目名：{}。听众是一个人，这是只给他听的节目。\n\
         从候选文章里挑出最多 {count} 篇来讲，按适合播出的顺序排列：先讲最重要或最有意思的，相近的话题挨着。\n\
         挑选的原则：听众的要求优先；权重 1 到 5，越大越该多挑这个来源；含有“不要的词”的不挑；同一件事只挑一篇。\n\
         只回 JSON，不要别的字：{{\"pick\": [编号, ...], \"skipped\": \"一句话说没挑的为什么没挑\"}}。skipped 用{lang}写。",
        show.name
    );
    let user = format!("听众的要求：{}\n不要的词：{avoid}\n\n候选：\n{list}", if show.brief.is_empty() { "无" } else { &show.brief });
    Prompt { system, user }
}

/// Step 4, 摘要: one article at a time. `comments` are Hacker News' top comments, if any.
#[uniffi::export]
pub fn summary_prompt(show: Show, title: String, source: String, text: String, comments: Vec<String>) -> Prompt {
    let lang = language_name(&show.language);
    let body = cut(&text, 6000);
    let mut user = format!("来源：{source}\n标题：{title}\n\n正文：\n{body}\n");
    if !comments.is_empty() {
        user.push_str("\n读者评论：\n");
        for c in comments.iter().take(8) {
            user.push_str(&format!("- {}\n", cut(c, 400)));
        }
    }
    let system = format!(
        "你在为一档播客准备材料。用{lang}把这篇文章写成要点，给后面写稿的人用：\n\
         1. 一句话说这篇讲的是什么。\n2. 三到六条要点：事实、数字、谁做了什么、为什么重要。只写原文里有的，不要补充原文没有的事实。\n\
         3. 有读者评论的话，用一两句说大家怎么看、有什么不同意见。\n\
         不要客套，不要“本文”“作者认为”这种开头。纯文字，不要 Markdown。"
    );
    Prompt { system, user }
}

/// Step 5, 写稿: the whole script from the summaries, in the JSON `parse_script` reads.
#[uniffi::export]
pub fn script_prompt(show: Show, date: String, articles: Vec<ScriptArticle>, summaries: Vec<String>) -> Prompt {
    let lang = language_name(&show.language);
    let target = target_units(&show);
    let hosts = match show.form {
        ShowForm::Solo => format!("一位主持人：{}，{}。", show.hosts[0].name, about(&show.hosts[0])),
        ShowForm::Duo => format!(
            "两位主持人对谈：{}，{}；{}，{}。两人有来有回，一个提问、打比方，一个讲清楚原理，不要一人念一大段。",
            show.hosts[0].name,
            about(&show.hosts[0]),
            show.hosts[1].name,
            about(&show.hosts[1])
        ),
    };
    let names: Vec<&str> = show.hosts.iter().map(|h| h.name.as_str()).collect();
    let system = format!(
        "你在写一档个人播客的稿子，节目名：{}，日期：{date}。用{lang}写，写成说出来的话：短句、口语，不念网址，数字说得出口。\n\
         {hosts}\n\
         全集大约 {target} 字（{minutes} 分钟）。开头一两句问好、说今天讲几件事；每件事一段；结尾一两句道别。\n\
         只讲材料里有的，不编造事实；不确定的就说“原文没说”。\n\
         只回 JSON，不要别的字：\n\
         {{\"title\": \"这一集的标题，二十字以内\", \"summary\": \"一两句简介\", \"segments\": [{{\"topic\": \"这一段的话题\", \"articles\": [材料编号], \"lines\": [{{\"who\": \"主持人名字\", \"text\": \"一句话\"}}]}}]}}\n\
         who 只能是：{}。开头和结尾的段 articles 写 []。",
        show.name,
        names.join("、"),
        minutes = show.minutes
    );
    let mut user = String::from("材料：\n");
    for (i, (a, s)) in articles.iter().zip(&summaries).enumerate() {
        user.push_str(&format!("\n[{i}] {}（{}）\n{}\n", a.title, a.source, s.trim()));
    }
    if !show.brief.is_empty() {
        user.push_str(&format!("\n听众的要求：{}\n", show.brief));
    }
    Prompt { system, user }
}

/// 编辑部: the reader talks to the editor about today's pick ("放最后", "不要这条").
#[uniffi::export]
pub fn editor_prompt(show: Show, picked: Vec<String>, skipped: String, message: String) -> Prompt {
    let lang = language_name(&show.language);
    let list: String = picked.iter().enumerate().map(|(i, t)| format!("{}. {t}\n", i + 1)).collect();
    let system = format!(
        "你是一档个人播客“{}”的编辑，正在和唯一的听众商量今天这一集讲什么。用{lang}回答，像人说话，一两句就好。\n\
         听众要改，就照改，并说清楚改了什么、这一集大概会长多少或短多少。\n\
         只回 JSON：{{\"reply\": \"你对听众说的话\", \"pick\": [调整后的文章序号，从 1 开始]}}。",
        show.name
    );
    let user = format!("现在挑的：\n{list}\n没挑的：{skipped}\n\n听众说：{message}");
    Prompt { system, user }
}

/// What the model answered to `pick_prompt` (or `editor_prompt`): the picked indexes, the line
/// about the rest, and the editor's reply when it is one.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Pick {
    pub pick: Vec<u32>,
    pub skipped: String,
    pub reply: Option<String>,
}

/// Reads the answer to `pick_prompt` or `editor_prompt`. Indexes not offered are dropped, and
/// one given twice is kept once.
#[uniffi::export]
pub fn parse_pick(answer: String, offered: Vec<u32>) -> Result<Pick> {
    let v = json_in(&answer)?;
    let mut seen = HashSet::new();
    let offered: HashSet<u32> = offered.into_iter().collect();
    let pick: Vec<u32> = v["pick"]
        .as_array()
        .ok_or_else(|| bad_answer("pick"))?
        .iter()
        .filter_map(|x| x.as_u64().or_else(|| x.as_str()?.trim().parse().ok()))
        .map(|x| x as u32)
        .filter(|x| offered.contains(x) && seen.insert(*x))
        .collect();
    Ok(Pick { pick, skipped: v["skipped"].as_str().unwrap_or_default().trim().to_string(), reply: v["reply"].as_str().map(|s| s.trim().to_string()) })
}

fn about(h: &ShowHost) -> String {
    if h.about.is_empty() { tr("说话平实", "plain-spoken") } else { h.about.clone() }
}

/// About this many characters (Chinese) or units (other languages) for the show's length.
fn target_units(show: &Show) -> u32 {
    let per_minute = if show.language.starts_with("zh") || show.language.starts_with("ja") { 220 } else { 320 };
    show.minutes * per_minute
}

fn language_name(code: &str) -> String {
    let c = code.to_ascii_lowercase();
    let name = if c.starts_with("zh-hant") || c == "zh-tw" || c == "zh-hk" {
        "繁体中文"
    } else if c.starts_with("zh") || c.is_empty() {
        "简体中文"
    } else if c.starts_with("en") {
        "英文"
    } else if c.starts_with("ja") {
        "日文"
    } else if c.starts_with("ko") {
        "韩文"
    } else if c.starts_with("fr") {
        "法文"
    } else if c.starts_with("de") {
        "德文"
    } else if c.starts_with("es") {
        "西班牙文"
    } else {
        return format!("语言 {code}");
    };
    name.to_string()
}

/// The first `max` units of `s`, cut at a paragraph or sentence when one is near.
fn cut(s: &str, max: u32) -> String {
    let mut out = String::new();
    let mut units = 0;
    for line in s.lines() {
        let u = Stats::of(line).units();
        if units + u > max {
            if units == 0 {
                out.extend(line.chars().take(max as usize));
            }
            break;
        }
        out.push_str(line);
        out.push('\n');
        units += u;
    }
    out.trim_end().to_string()
}

// ---------------------------------------------------------------------------------------------
// The script

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ScriptArticle {
    pub title: String,
    pub url: String,
    /// "少数派", "rust-lang/rust".
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ScriptLine {
    /// The host's name.
    pub who: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ScriptSegment {
    pub topic: String,
    /// Indexes into `EpisodeScript::articles`; none for the opening and the goodbye.
    pub articles: Vec<u32>,
    pub lines: Vec<ScriptLine>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct EpisodeScript {
    pub title: String,
    pub summary: String,
    pub articles: Vec<ScriptArticle>,
    pub segments: Vec<ScriptSegment>,
}

#[derive(Serialize, Deserialize, Default)]
struct ArticleJson {
    title: String,
    url: String,
    source: String,
}

fn article_json(a: &ScriptArticle) -> ArticleJson {
    ArticleJson { title: a.title.clone(), url: a.url.clone(), source: a.source.clone() }
}

fn script_json(s: &EpisodeScript) -> Value {
    json!({
        "title": s.title,
        "summary": s.summary,
        "articles": s.articles.iter().map(article_json).collect::<Vec<_>>(),
        "segments": s.segments.iter().map(|g| json!({
            "topic": g.topic,
            "articles": g.articles,
            "lines": g.lines.iter().map(|l| json!({ "who": l.who, "text": l.text })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

/// A script as `script_json` wrote it, from an episode's file.
fn script_from_json(v: &Value) -> Option<EpisodeScript> {
    let str_of = |v: &Value, k: &str| v[k].as_str().unwrap_or_default().to_string();
    Some(EpisodeScript {
        title: v["title"].as_str()?.to_string(),
        summary: str_of(v, "summary"),
        articles: v["articles"].as_array()?.iter().map(|a| ScriptArticle { title: str_of(a, "title"), url: str_of(a, "url"), source: str_of(a, "source") }).collect(),
        segments: v["segments"]
            .as_array()?
            .iter()
            .map(|g| ScriptSegment {
                topic: str_of(g, "topic"),
                articles: g["articles"].as_array().into_iter().flatten().filter_map(Value::as_u64).map(|n| n as u32).collect(),
                lines: g["lines"].as_array().into_iter().flatten().map(|l| ScriptLine { who: str_of(l, "who"), text: str_of(l, "text") }).collect(),
            })
            .collect(),
    })
}

impl YuyueCore {
    /// An episode's file brought from another device (同步 · 书文件): built into the same book
    /// here, by its show as the log has it. Not a TXT, though the file is text.
    pub(crate) fn import_episode(&self, bytes: &[u8]) -> Result<Manifest> {
        let v: Value = serde_json::from_slice(bytes).map_err(|_| CoreError::bad_book("not an episode"))?;
        let (Some(show), Some(date), Some(script)) = (v["show"].as_str(), v["date"].as_str(), script_from_json(&v["script"])) else {
            return Err(CoreError::bad_book("not an episode"));
        };
        let s = self.show(show.to_string())?;
        let id = book::book_id(bytes);
        let manifest = book::build_into(&self.books_dir, &id, |tmp| build_episode(tmp, &id, &s, date, &script, bytes))?;
        Ok(manifest)
    }
}

/// Checks the answer to `script_prompt` and reads it. Hosts' names are matched loosely (a
/// model writes "老周：" or "Lao Zhou"); a line no host can be found for, an empty segment, or
/// an article index that wasn't given is an error saying which, so the app can ask again once.
#[uniffi::export]
pub fn parse_script(answer: String, show: Show, articles: Vec<ScriptArticle>) -> Result<EpisodeScript> {
    let v = json_in(&answer)?;
    let title = v["title"].as_str().map(text::collapse_ws).filter(|t| !t.is_empty()).ok_or_else(|| bad_answer("title"))?;
    let summary = v["summary"].as_str().map(text::collapse_ws).unwrap_or_default();
    let segs = v["segments"].as_array().filter(|a| !a.is_empty()).ok_or_else(|| bad_answer("segments"))?;
    let names: Vec<String> = show.hosts.iter().map(|h| h.name.trim().to_string()).collect();
    let mut segments = Vec::new();
    for (i, g) in segs.iter().enumerate() {
        let lines_v = g["lines"].as_array().ok_or_else(|| bad_answer(&format!("segments[{i}].lines")))?;
        let mut lines = Vec::new();
        for (j, l) in lines_v.iter().enumerate() {
            let text = l["text"].as_str().map(text::collapse_ws).unwrap_or_default();
            if Stats::of(&text).units() == 0 {
                continue;
            }
            let who_raw = l["who"].as_str().unwrap_or_default();
            let who = match_host(who_raw, &names).ok_or_else(|| CoreError::Invalid {
                detail: format!("{}segments[{i}].lines[{j}]：{who_raw}", tr("稿子里有不认识的主持人，", "The script has a host it doesn't know, ")),
            })?;
            lines.push(ScriptLine { who, text });
        }
        if lines.is_empty() {
            continue;
        }
        let mut refs = Vec::new();
        for a in g["articles"].as_array().map(Vec::as_slice).unwrap_or_default() {
            let n = a.as_u64().or_else(|| a.as_str()?.trim().trim_matches(['[', ']']).parse().ok()).ok_or_else(|| bad_answer(&format!("segments[{i}].articles")))?;
            if n as usize >= articles.len() {
                return Err(CoreError::Invalid { detail: format!("{}segments[{i}]：{n}", tr("稿子引用了没有的材料，", "The script cites an article it wasn't given, ")) });
            }
            if !refs.contains(&(n as u32)) {
                refs.push(n as u32);
            }
        }
        segments.push(ScriptSegment { topic: g["topic"].as_str().map(text::collapse_ws).unwrap_or_default(), articles: refs, lines });
    }
    if segments.is_empty() {
        return Err(bad_answer("segments"));
    }
    Ok(EpisodeScript { title, summary, articles, segments })
}

/// "老周：" → "老周"; case and spaces don't count; a name inside a longer one ("主持人老周").
fn match_host(raw: &str, names: &[String]) -> Option<String> {
    let norm = |s: &str| s.chars().filter(|c| !c.is_whitespace() && !"：:「」\"'".contains(*c)).collect::<String>().to_lowercase();
    let r = norm(raw);
    if r.is_empty() {
        return (names.len() == 1).then(|| names[0].clone());
    }
    names.iter().find(|n| norm(n) == r).or_else(|| names.iter().find(|n| r.contains(&norm(n)))).cloned()
}

/// The JSON object in a model's answer: alone, in a ```json fence, or after a sentence.
fn json_in(answer: &str) -> Result<Value> {
    let t = answer.trim();
    let t = t.strip_prefix("```json").or_else(|| t.strip_prefix("```")).map(|r| r.trim_end().trim_end_matches("```")).unwrap_or(t);
    if let Ok(v) = serde_json::from_str::<Value>(t.trim())
        && v.is_object() {
            return Ok(v);
        }
    let (Some(s), Some(e)) = (t.find('{'), t.rfind('}')) else { return Err(bad_answer("JSON")) };
    serde_json::from_str::<Value>(&t[s..=e]).ok().filter(Value::is_object).ok_or_else(|| bad_answer("JSON"))
}

fn bad_answer(what: &str) -> CoreError {
    CoreError::Invalid { detail: format!("{}{what}", tr("模型交回的格式不对：", "The model's answer isn't in the right form: ")) }
}

// ---------------------------------------------------------------------------------------------
// The episode as a book

/// The section: a heading, then each segment as a `<section>` with its source line and one
/// `<p>` per line. `<p data-who>` says who speaks it, for the player to pick that host's voice
/// and the reader to show the speaker; the source line's link opens the article.
fn script_body(show: &Show, script: &EpisodeScript) -> Element {
    let mut body = Element::new("body");
    body.children.push(Node::Element(Element::new("h1").with_text(script.title.clone())));
    if !script.summary.is_empty() {
        body.children.push(Node::Element(Element::new("p").with_attr("class", "yy-pod-summary").with_text(script.summary.clone())));
    }
    let host_index = |who: &str| show.hosts.iter().position(|h| h.name == who).unwrap_or(0);
    for seg in &script.segments {
        let mut sec = Element::new("section").with_attr("class", "yy-pod-seg");
        if !seg.topic.is_empty() && !seg.articles.is_empty() {
            sec.children.push(Node::Element(Element::new("h2").with_text(seg.topic.clone())));
        }
        if !seg.articles.is_empty() {
            let mut src = Element::new("div").with_attr("class", "yy-pod-src");
            for (k, &a) in seg.articles.iter().enumerate() {
                let art = &script.articles[a as usize];
                if k > 0 {
                    src.children.push(Node::Text(" · ".into()));
                }
                let label = if art.source.is_empty() { art.title.clone() } else { format!("{} · {}", art.source, art.title) };
                src.children.push(Node::Element(Element::new("a").with_attr("href", art.url.clone()).with_text(label)));
            }
            sec.children.push(Node::Element(src));
        }
        let mut last: Option<&str> = None;
        for l in &seg.lines {
            let i = host_index(&l.who);
            // The first of a host's lines in a row carries their name.
            let first = if last != Some(l.who.as_str()) { " yy-pod-first" } else { "" };
            last = Some(&l.who);
            let p = Element::new("p").with_attr("class", format!("yy-pod-line yy-pod-h{i}{first}")).with_attr("data-who", l.who.clone()).with_text(l.text.clone());
            sec.children.push(Node::Element(p));
        }
        body.children.push(Node::Element(sec));
    }
    body
}

fn build_episode(tmp: &Path, id: &str, show: &Show, date: &str, script: &EpisodeScript, original: &[u8]) -> Result<Manifest> {
    fs::write(tmp.join("original.podcast"), original)?;
    let language = if show.language.is_empty() { text::guess_language(&script.title).to_string() } else { show.language.clone() };
    let no_resource = |_: &str| None;
    let link = |href: &str| if href.starts_with("http://") || href.starts_with("https://") { Link::External(href.to_string()) } else { Link::Dead };
    let ctx = Context { lang: &language, resource: &no_resource, link: &link };
    let normalized = normalize::normalize(script_body(show, script), &ctx);
    let stats = normalized.stats;
    let info = SectionInfo {
        title: Some(script.title.clone()),
        lang: None,
        styles: Vec::new(),
        body_class: Some("yy-podcast".into()),
        linear: true,
        kind: Kind::Text,
        continued: false,
        sentences: normalized.sentences.len() as u32,
        units: stats.units(),
        pages: 0,
        ms: 0,
    };
    let s = tmp.join("s");
    fs::write(s.join("0.html"), dom::to_html(&normalized.content))?;
    fs::write(s.join("0.json"), serde_json::to_string(&normalized.sentences)?)?;
    fs::write(s.join("0.who.json"), serde_json::to_string(&speakers(&normalized.content, normalized.sentences.len()))?)?;
    let manifest = Manifest {
        version: book::FORMAT_VERSION,
        id: id.to_string(),
        format: Format::Podcast,
        title: script.title.clone(),
        authors: vec![show.name.clone()],
        language,
        isbn: None,
        cover: None,
        start: 0,
        sections: vec![info],
        toc: vec![TocEntry { title: format!("{} · {date}", show.name), depth: 0, section: 0, anchor: None }],
        units: stats.units(),
        read_minutes: stats.read_minutes(),
        listen_minutes: stats.listen_minutes(),
    };
    fs::write(tmp.join("book.json"), serde_json::to_string_pretty(&manifest)?)?;
    Ok(manifest)
}

/// Who speaks each sentence: the `data-who` of the `<p>` it's in, or none (the title, a
/// source line).
fn speakers(content: &[Node], count: usize) -> Vec<Option<String>> {
    let mut out = vec![None; count];
    fn walk(nodes: &[Node], who: Option<&str>, out: &mut [Option<String>]) {
        for n in nodes {
            let Node::Element(e) = n else { continue };
            let who = e.attr("data-who").or(who);
            if let (Some(s), true) = (e.attr("data-s"), e.has_class("s"))
                && let Ok(i) = s.parse::<usize>()
                    && let (Some(slot), Some(w)) = (out.get_mut(i), who) {
                        slot.get_or_insert_with(|| w.to_string());
                    }
            walk(&e.children, who, out);
        }
    }
    walk(content, None, &mut out);
    out
}

#[uniffi::export]
impl YuyueCore {
    /// Who speaks each sentence of a section of an episode, for the player to give each host
    /// their voice: a host's name, or none for the title and source lines. Empty for a book.
    pub fn section_speakers(&self, book_id: String, section: u32) -> Result<Vec<Option<String>>> {
        let dir = self.book_dir(&book_id)?;
        match fs::read_to_string(dir.join("s").join(format!("{section}.who.json"))) {
            Ok(t) => Ok(serde_json::from_str(&t)?),
            Err(_) => Ok(Vec::new()),
        }
    }
}

/// An episode taken off the list (`prune_heard_episodes`).
fn gone(f: &std::collections::BTreeMap<String, Value>) -> bool {
    f.get("deleted") == Some(&json!(true))
}

#[cfg(test)]
#[path = "podcast_tests.rs"]
mod tests;
