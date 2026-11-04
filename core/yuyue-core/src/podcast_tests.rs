use super::*;
use crate::feed::*;
use crate::api::BookFormat;

fn feed_fixture(name: &str) -> Vec<u8> {
    fs::read(format!("{}/../../fixtures/feeds/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

fn temp(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("yuyue-podcast-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir.to_string_lossy().into_owned()
}

fn duo() -> ShowDraft {
    ShowDraft {
        name: "科技早报".into(),
        sources: vec![ShowSource { kind: SourceKind::Feed, address: "https://sspai.com/feed".into(), name: "少数派".into(), weight: 9, limit: 0, paused: false }],
        schedule: ShowSchedule { days: vec![5, 1, 2, 3, 4, 4], minute: 7 * 60 },
        minutes: 10,
        form: ShowForm::Duo,
        hosts: vec![
            ShowHost { name: "小林".into(), about: "做产品的，好奇心重，爱打比方".into(), voice: Some("晓晓".into()) },
            ShowHost { name: "老周".into(), about: "写了二十年代码，讲原理".into(), voice: None },
        ],
        language: "zh-CN".into(),
        brief: "多讲开源工具，少讲融资".into(),
        avoid: vec![" 融资 ".into(), "".into()],
        device: None,
    }
}

// --- feeds ----------------------------------------------------------------------------------

#[test]
fn reads_an_rss_feed_with_only_summaries() {
    let f = parse_feed(feed_fixture("sspai.xml"), "https://sspai.com/feed".into()).unwrap();
    assert_eq!(f.title, "少数派");
    assert_eq!(f.site.as_deref(), Some("https://sspai.com"));
    assert!(f.items.len() >= 5);
    let first = &f.items[0];
    assert!(first.url.starts_with("https://sspai.com/post/"));
    assert!(!first.title.is_empty());
    // 2026-10-31 13:29:19 +0800, more or less: a date in the past week.
    assert!(first.published.is_some_and(|t| t > 1_790_000_000_000));
    assert!(first.summary_only, "少数派's feed carries summaries");
    assert!(!first.text.contains('<'));
}

#[test]
fn reads_atom_feeds() {
    let f = parse_feed(feed_fixture("rust-blog.atom"), "https://blog.rust-lang.org/feed.xml".into()).unwrap();
    assert_eq!(f.title, "Rust Blog");
    let a = &f.items[0];
    assert!(a.url.starts_with("https://blog.rust-lang.org/"));
    assert!(!a.summary_only, "the Rust blog's feed carries whole posts");
    assert!(text::Stats::of(&a.text).units() > 600);

    let r = parse_feed(feed_fixture("ruanyifeng.atom"), "https://www.ruanyifeng.com/blog/atom.xml".into()).unwrap();
    assert!(r.items[0].url.contains("ruanyifeng.com/blog/2026/"));

    let gh = parse_feed(feed_fixture("rust-releases.atom"), "https://github.com/rust-lang/rust/releases.atom".into()).unwrap();
    assert!(gh.items.iter().any(|i| i.url.contains("/releases/tag/")));

    let v = parse_feed(feed_fixture("v2ex.atom"), "https://www.v2ex.com/index.xml".into()).unwrap();
    assert!(v.items.len() > 10 && v.items.iter().all(|i| i.url.starts_with("https://")));
}

#[test]
fn reads_hacker_news() {
    let f = parse_feed(feed_fixture("hn.xml"), "https://news.ycombinator.com/rss".into()).unwrap();
    assert_eq!(f.items.len(), 30);

    let story = parse_hn_item(feed_fixture("hn-item.json")).unwrap().unwrap();
    assert_eq!((story.id, story.score, story.comments), (8863, Some(104), Some(71)));
    assert_eq!(story.kids.len(), 33);
    let item = hn_feed_item(story);
    assert_eq!(item.url, "http://www.getdropbox.com/u/2/screencast.html");
    assert_eq!(item.discussion.as_deref(), Some("https://news.ycombinator.com/item?id=8863"));
    assert_eq!(item.published, Some(1_175_714_200_000));

    let comment = parse_hn_item(br#"{"id":1,"type":"comment","by":"a","text":"I <i>really</i> like it.<p>Second &amp; last.","kids":[2]}"#.to_vec()).unwrap().unwrap();
    assert_eq!(comment.text, "I really like it.\nSecond & last.");
    assert_eq!(comment.comments, None);
    assert_eq!(parse_hn_item(br#"{"id":3,"deleted":true}"#.to_vec()).unwrap(), None);
    assert_eq!(parse_hn_item(b"null".to_vec()).unwrap(), None);
    assert_eq!(parse_hn_ids(b"[3, 1, 2]".to_vec()).unwrap(), vec![3, 1, 2]);
}

#[test]
fn reads_feeds_in_other_encodings_and_shapes() {
    let gbk = encoding_rs::GBK.encode("<?xml version=\"1.0\" encoding=\"gbk\"?><rss><channel><title>中文站</title><item><title>第一篇</title><link>/a/1</link><description>&lt;p&gt;摘要&lt;/p&gt;</description></item></channel></rss>").0;
    let f = parse_feed(gbk.into_owned(), "https://example.cn/feed".into()).unwrap();
    assert_eq!((f.title.as_str(), f.items[0].title.as_str(), f.items[0].url.as_str(), f.items[0].text.as_str()), ("中文站", "第一篇", "https://example.cn/a/1", "摘要"));

    // RSS 1.0 keeps items beside the channel.
    let rdf = br#"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>RDF</title><link>https://r.example/</link></channel><item><title>One</title><link>https://r.example/1</link><dc:date>2026-10-31T05:29:19Z</dc:date><dc:creator>Ann</dc:creator></item></rdf:RDF>"#;
    let f = parse_feed(rdf.to_vec(), "https://r.example/rss".into()).unwrap();
    assert_eq!(f.items[0].author.as_deref(), Some("Ann"));
    assert_eq!(f.items[0].published, Some(1_793_424_559_000));

    assert!(parse_feed(b"<html><body>not a feed</body></html>".to_vec(), "https://x.example/".into()).is_err());
    assert!(parse_feed(b"{}".to_vec(), "https://x.example/".into()).is_err());
}

#[test]
fn reads_dates() {
    assert_eq!(parse_date("Sat, 31 Oct 2026 13:29:19 +0800"), Some(1_793_424_559_000));
    assert_eq!(parse_date("2026-10-31T05:29:19Z"), Some(1_793_424_559_000));
    assert_eq!(parse_date("2026-10-31T13:29:19.250+08:00"), Some(1_793_424_559_000));
    assert_eq!(parse_date("31 Oct 2026 05:29:19 GMT"), Some(1_793_424_559_000));
    assert_eq!(parse_date("Fri, 30 Oct 2026 22:29:19 PDT"), Some(1_793_424_559_000));
    assert_eq!(parse_date("2026-10-31"), Some(1_793_404_800_000));
    assert_eq!(parse_date("someday"), None);
    assert_eq!(parse_date("2026-13-01"), None);
}

#[test]
fn finds_a_pages_feeds() {
    let html = String::from_utf8(feed_fixture("rust-blog.html")).unwrap();
    let links = feed_links(html, "https://blog.rust-lang.org/".into());
    assert_eq!(links[0].url, "https://blog.rust-lang.org/feed.xml");
    let links = feed_links(
        r#"<head><link rel="alternate" type="application/rss+xml" href="/feed" title=" 博客 "><link rel="alternate" type="application/rss+xml" href="/feed"><link rel="stylesheet" href="a.css"><link rel="Alternate" type="application/atom+xml" href="atom.xml"></head>"#.into(),
        "https://a.example/blog/post.html".into(),
    );
    let urls: Vec<&str> = links.iter().map(|l| l.url.as_str()).collect();
    assert_eq!(urls, ["https://a.example/feed", "https://a.example/blog/atom.xml"]);
    assert_eq!(links[0].title.as_deref(), Some("博客"));
}

#[test]
fn resolves_links() {
    let b = "https://a.example/x/y/page.html?q=1";
    assert_eq!(resolve(b, "/z").as_deref(), Some("https://a.example/z"));
    assert_eq!(resolve(b, "z").as_deref(), Some("https://a.example/x/y/z"));
    assert_eq!(resolve(b, "../z").as_deref(), Some("https://a.example/x/z"));
    assert_eq!(resolve(b, "//cdn.example/z").as_deref(), Some("https://cdn.example/z"));
    assert_eq!(resolve(b, "http://b.example/").as_deref(), Some("http://b.example/"));
    assert_eq!(resolve(b, "javascript:alert(1)"), None);
    assert_eq!(resolve(b, "mailto:a@b.c"), None);
}

#[test]
fn one_key_for_one_article() {
    let k = article_key("https://sspai.com/post/117960".into());
    for same in ["http://www.sspai.com/post/117960/", "https://sspai.com/post/117960?utm_source=rss&utm_medium=feed", "https://sspai.com/post/117960#comments"] {
        assert_eq!(article_key(same.into()), k, "{same}");
    }
    assert_ne!(article_key("https://sspai.com/post/117961".into()), k);
    assert_eq!(article_key("https://a.example/?b=2&a=1".into()), article_key("https://a.example/?a=1&b=2".into()));
    assert_ne!(article_key("https://a.example/?id=1".into()), article_key("https://a.example/?id=2".into()));
}

// --- article text ---------------------------------------------------------------------------

#[test]
fn takes_an_articles_text_and_leaves_the_page() {
    let rust = article(String::from_utf8(feed_fixture("rust-post.html")).unwrap());
    assert_eq!(rust.title.as_deref(), Some("How to fund Rust contributors"));
    assert!(rust.units > 800, "{}", rust.units);
    let all = rust.paragraphs.join("\n");
    assert!(!all.contains("Get help!") && !all.contains("Policies"), "the footer is left out");

    let sspai = article(String::from_utf8(feed_fixture("sspai-post.html")).unwrap());
    assert_eq!(sspai.title.as_deref(), Some("时间管理：我实践柳比歇夫法的176天"));
    assert!(sspai.units > 5000, "{} {:?}", sspai.units, sspai.paragraphs.iter().take(3).collect::<Vec<_>>());
    let all = sspai.paragraphs.join("\n");
    assert!(!all.contains("本文责编") && !all.contains("著作权归作者所有"), "the footer is left out");
    assert!(sspai.paragraphs.iter().all(|p| !p.contains("window.") && !p.contains("function(")));

    let simon = article(String::from_utf8(feed_fixture("simonw-post.html")).unwrap());
    assert!(simon.units > 100, "{}", simon.units);
}

#[test]
fn an_article_without_its_menus_and_comments() {
    let page = r#"<html><head><title>好文章 - 某网站</title></head><body>
        <header><nav><ul><li><a href="/">首页</a></li><li><a href="/a">文章</a></li></ul></nav></header>
        <div class="layout"><div class="sidebar"><p>热门推荐：这是一段很长的侧栏文字，介绍别的文章，不应该出现在正文里面。</p></div>
        <div class="post-content"><h1>好文章</h1><p>第一段讲了一件事，这件事很重要，所以写得比较长一些，<a href="/x">链接</a>也在里面。</p>
        <p>第二段接着讲，讲清楚为什么。<br>换行以后还是这一段的话。</p><ul><li>要点一：一个具体的数字是 42。</li></ul>
        <script>var x = 1;</script></div>
        <div id="comments"><p>评论：写得真好，作者辛苦了，期待下一篇更长更好的文章。</p></div></div>
        <footer><p>版权所有 © 某网站 2026，保留所有权利。</p></footer></body></html>"#;
    let a = article(page.into());
    assert_eq!(a.title.as_deref(), Some("好文章"));
    assert_eq!(
        a.paragraphs,
        ["第一段讲了一件事，这件事很重要，所以写得比较长一些，链接也在里面。", "第二段接着讲，讲清楚为什么。换行以后还是这一段的话。", "要点一：一个具体的数字是 42。"]
    );
}

// --- shows ----------------------------------------------------------------------------------

#[test]
fn keeps_shows_in_the_log() {
    let dir = temp("shows");
    let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
    let s = core.add_show(duo()).unwrap();
    assert_eq!(s.schedule.days, vec![1, 2, 3, 4, 5]);
    assert_eq!(s.sources[0].weight, 5);
    assert_eq!(s.sources[0].limit, 1);
    assert_eq!(s.avoid, vec!["融资"]);
    assert_eq!(s.hosts[0].voice, None, "voices stay on each device");
    assert_eq!(s.device.as_deref(), Some(core.device_id().as_str()));
    assert_eq!(core.shows().unwrap(), vec![s.clone()]);

    let mut d = duo();
    d.minutes = 20;
    let changed = core.update_show(s.id.clone(), d).unwrap();
    assert_eq!(changed.minutes, 20);
    assert_eq!(changed.created_at, s.created_at);

    let mut bad = duo();
    bad.form = ShowForm::Solo;
    assert!(core.add_show(bad).is_err(), "two hosts for a solo show");
    let mut bad = duo();
    bad.hosts[1].name = "小林 ".into();
    assert!(core.add_show(bad).is_err());
    let mut bad = duo();
    bad.schedule.days = vec![8];
    assert!(core.add_show(bad).is_err());

    // Another device sees it after a sync.
    let other = YuyueCore::open(temp("shows-2"), "iPhone".into(), "ios".into()).unwrap();
    let batch = lock(&core.store).export(&Default::default()).unwrap();
    lock(&other.store).import(&batch).unwrap();
    assert_eq!(other.shows().unwrap()[0].name, "科技早报");

    core.remove_show(s.id.clone()).unwrap();
    assert!(core.shows().unwrap().is_empty());
    assert!(core.show(s.id).is_err());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn remembers_told_articles_on_this_device_only() {
    let dir = temp("told");
    let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
    let s = core.add_show(duo()).unwrap();
    assert!(core.told_articles(s.id.clone()).unwrap().is_empty());
    core.mark_told(s.id.clone(), vec!["a".into(), "b".into()]).unwrap();
    core.mark_told(s.id.clone(), vec!["b".into(), "c".into()]).unwrap();
    assert_eq!(core.told_articles(s.id.clone()).unwrap(), ["a", "b", "c"]);
    assert!(lock(&core.store).export(&Default::default()).unwrap().ops.iter().all(|o| !o.value.to_string().contains("\"c\"")));
    assert!(core.told_articles("../x".into()).is_err());
    let _ = fs::remove_dir_all(&dir);
}

// --- prompts and answers --------------------------------------------------------------------

fn show(core: &YuyueCore) -> Show {
    core.add_show(duo()).unwrap()
}

#[test]
fn prompts_say_what_the_show_wants() {
    let core = YuyueCore::open(temp("prompts"), "Mac".into(), "macos".into()).unwrap();
    let s = show(&core);
    let p = pick_prompt(s.clone(), vec![Candidate { index: 3, title: "uv 0.9".into(), source: "GitHub".into(), weight: 4 }], 7);
    assert!(p.system.contains("科技早报") && p.system.contains("最多 7 篇"));
    assert!(p.user.contains("多讲开源工具") && p.user.contains("融资") && p.user.contains("3. [GitHub] uv 0.9"));

    let long = "一段话。".repeat(4000);
    let p = summary_prompt(s.clone(), "标题".into(), "少数派".into(), long, vec!["好".into()]);
    assert!(text::Stats::of(&p.user).units() < 6200);
    assert!(p.user.contains("读者评论"));

    let a = vec![ScriptArticle { title: "Rust 1.91".into(), url: "https://blog.rust-lang.org/".into(), source: "Rust Blog".into() }];
    let p = script_prompt(s, "2026-11-01".into(), a, vec!["编译快了两成".into()]);
    assert!(p.system.contains("小林") && p.system.contains("老周") && p.system.contains("2200 字"));
    assert!(p.user.contains("[0] Rust 1.91（Rust Blog）\n编译快了两成"));
}

#[test]
fn reads_the_editors_pick() {
    let p = parse_pick("好的，挑了这些：\n```json\n{\"pick\": [3, \"1\", 3, 99], \"skipped\": \" 讲融资的不挑 \"}\n```".into(), vec![1, 2, 3]).unwrap();
    assert_eq!((p.pick, p.skipped.as_str(), p.reply), (vec![3, 1], "讲融资的不挑", None));
    let p = parse_pick(r#"{"reply":"好，放最后了。","pick":[2,1]}"#.into(), vec![1, 2]).unwrap();
    assert_eq!(p.reply.as_deref(), Some("好，放最后了。"));
    assert!(parse_pick("我不知道".into(), vec![1]).is_err());
}

fn answer() -> String {
    r#"```json
{"title":"SQLite 当消息队列，和 Rust 的新版本","summary":"两件事。","segments":[
 {"topic":"开场","articles":[],"lines":[{"who":"小林","text":"早上好，今天讲两件事。"},{"who":"老周：","text":"先说 Rust。"}]},
 {"topic":"Rust 1.91","articles":[0,"1",0],"lines":[{"who":"老周","text":"这次编译快了一截。大项目能省两成时间。"},{"who":"主持人小林","text":"两成是什么概念？"},{"who":"小林","text":"  "}]},
 {"topic":"空的","articles":[1],"lines":[]},
 {"topic":"结尾","articles":[],"lines":[{"who":"老周","text":"明天见。"}]}]}
```"#
    .into()
}

fn articles() -> Vec<ScriptArticle> {
    vec![
        ScriptArticle { title: "Rust 1.91 发布".into(), url: "https://blog.rust-lang.org/2026/10/30/Rust-1.91.0/".into(), source: "Rust Blog".into() },
        ScriptArticle { title: "Announcing Rust 1.91.0".into(), url: "https://github.com/rust-lang/rust/releases/tag/1.91.0".into(), source: "rust-lang/rust".into() },
    ]
}

#[test]
fn checks_the_script() {
    let core = YuyueCore::open(temp("script"), "Mac".into(), "macos".into()).unwrap();
    let s = show(&core);
    let script = parse_script(answer(), s.clone(), articles()).unwrap();
    assert_eq!(script.segments.len(), 3, "the empty segment is dropped");
    assert_eq!(script.segments[1].articles, vec![0, 1]);
    assert_eq!(script.segments[0].lines[1].who, "老周");
    assert_eq!(script.segments[1].lines[1].who, "小林");
    assert_eq!(script.segments[1].lines.len(), 2, "the blank line is dropped");

    let stranger = answer().replace("\"who\":\"老周\",\"text\":\"明天见", "\"who\":\"小王\",\"text\":\"明天见");
    let e = parse_script(stranger, s.clone(), articles()).unwrap_err();
    assert!(e.to_string().contains("小王"), "{e}");
    let cites = answer().replace("[0,\"1\",0]", "[5]");
    assert!(parse_script(cites, s.clone(), articles()).is_err());
    assert!(parse_script("{\"title\":\"x\",\"segments\":[]}".into(), s.clone(), articles()).is_err());
    assert!(parse_script("不是 JSON".into(), s, articles()).is_err());
}

#[test]
fn an_episode_is_a_book_with_speakers() {
    let dir = temp("episode");
    let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
    let s = show(&core);
    let script = parse_script(answer(), s.clone(), articles()).unwrap();
    let e = core.save_episode(s.id.clone(), "2026-11-01".into(), script.clone()).unwrap();
    assert_eq!((e.title.as_str(), e.date.as_str(), e.articles.len(), e.heard), ("SQLite 当消息队列，和 Rust 的新版本", "2026-11-01", 2, false));

    let b = core.summary(&e.book).unwrap();
    assert_eq!(b.format, BookFormat::Podcast);
    assert_eq!(b.authors, vec!["科技早报".to_string()]);
    let sentences = core.sentences(e.book.clone(), 0).unwrap();
    let who = core.section_speakers(e.book.clone(), 0).unwrap();
    assert_eq!(who.len(), sentences.len());
    let pairs: Vec<(Option<&str>, &str)> = who.iter().map(|w| w.as_deref()).zip(sentences.iter().map(String::as_str)).collect();
    assert_eq!(pairs[0], (None, "SQLite 当消息队列，和 Rust 的新版本"), "the title has no speaker");
    assert!(pairs.contains(&(Some("老周"), "这次编译快了一截。")));
    assert!(pairs.contains(&(Some("老周"), "大项目能省两成时间。")));
    assert!(pairs.contains(&(Some("小林"), "两成是什么概念？")));
    assert!(pairs.iter().any(|(w, t)| w.is_none() && t.contains("Rust Blog")), "the source line is read, by no host");
    let html = book::section_html(&core.book_dir(&e.book).unwrap(), 0).unwrap();
    assert!(html.contains("data-yy-external=\"https://blog.rust-lang.org/2026/10/30/Rust-1.91.0/\""), "{html}");
    assert!(html.contains("class=\"yy-pod-line yy-pod-h1 yy-pod-first\" data-who=\"老周\""), "{html}");

    // Saved again, it's the same episode.
    let again = core.save_episode(s.id.clone(), "2026-11-01".into(), script).unwrap();
    assert_eq!(again.book, e.book);
    assert_eq!(core.episodes(s.id.clone()).unwrap().len(), 1);
    assert_eq!(core.latest_episodes(10).unwrap()[0].book, e.book);

    // Not heard: kept, however old.
    assert_eq!(core.prune_heard_episodes(-1).unwrap(), 0);
    core.set_episode_heard(e.book.clone(), true).unwrap();
    assert!(core.episodes(s.id.clone()).unwrap()[0].heard);
    // Heard, but written just now: kept for the 30 days.
    assert_eq!(core.prune_heard_episodes(30 * 86_400_000).unwrap(), 0);
    // A bookmark in it: kept.
    let mark = core.add_bookmark(e.book.clone(), 0, 1).unwrap();
    assert_eq!(core.prune_heard_episodes(-1).unwrap(), 0);
    core.delete_bookmark(e.book.clone(), mark.id).unwrap();
    // A book has no speakers.
    assert!(core.section_speakers("0".repeat(32), 0).is_err() || core.section_speakers("0".repeat(32), 0).unwrap().is_empty());

    // It opens again from disk, without being rebuilt.
    drop(core);
    let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
    assert_eq!(core.sentences(e.book.clone(), 0).unwrap(), sentences);
    // Heard, old enough, nothing kept in it: it goes, from the list and the shelf.
    assert_eq!(core.prune_heard_episodes(-1).unwrap(), 1);
    assert!(core.episodes(s.id.clone()).unwrap().is_empty());
    assert!(core.latest_episodes(10).unwrap().is_empty());
    assert!(core.books().unwrap().iter().all(|b| b.id != e.book));
    core.remove_show(s.id).unwrap();
    let _ = fs::remove_dir_all(&dir);
}


/// Fills a scratch library for looking at the screens: `YUYUE_SEED=<dir> cargo test seed_demo -- --ignored`.
#[test]
#[ignore]
fn seed_demo() {
    let Ok(dir) = std::env::var("YUYUE_SEED") else { return };
    let core = YuyueCore::open(dir, "Mac".into(), "macos".into()).unwrap();
    let s = core.add_show(duo()).unwrap();
    let mut solo = duo();
    solo.name = "开源动态".into();
    solo.form = ShowForm::Solo;
    solo.hosts.truncate(1);
    core.add_show(solo).unwrap();
    let script = parse_script(answer(), s.clone(), articles()).unwrap();
    core.save_episode(s.id.clone(), "2026-11-01".into(), script).unwrap();
    println!("show {}", s.id);
}

/// 到点自己出新一集: due once a slot has passed on the device that writes the show, not on others,
/// not for a slot from long ago, and not once an episode came after it.
#[test]
fn shows_come_due_on_their_own_device() {
    let dir = temp("due");
    let core = YuyueCore::open(dir.clone(), "Mac".into(), "macos".into()).unwrap();
    let minute = 60_000i64;
    let made = core.add_show(duo()).unwrap();
    // Every day, an hour before three days from now.
    let now = made.created_at + 3 * 86_400_000;
    let at = ((now - 60 * minute).rem_euclid(86_400_000) / minute) as u32;
    let mut d = duo();
    d.schedule = ShowSchedule { days: (1..=7).collect(), minute: at };
    let s = core.update_show(made.id.clone(), d.clone()).unwrap();
    let due = core.due_shows(now, 0).unwrap();
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].show, s.id);
    assert!(now - due[0].slot_ms >= 59 * minute && now - due[0].slot_ms <= 61 * minute);
    // Only when asked: never due.
    let mut asked = d.clone();
    asked.schedule.days = vec![];
    core.update_show(s.id.clone(), asked).unwrap();
    assert!(core.due_shows(now, 0).unwrap().is_empty());
    core.update_show(s.id.clone(), d.clone()).unwrap();
    // A slot from long ago isn't caught up.
    let mut late = d.clone();
    late.schedule.minute = ((now + 2 * 60 * minute).rem_euclid(86_400_000) / minute) as u32;
    core.update_show(s.id.clone(), late).unwrap();
    assert!(core.due_shows(now, 0).unwrap().is_empty(), "the last slot was 22 hours ago");
    core.update_show(s.id.clone(), d.clone()).unwrap();
    // Started 20 minutes ahead, so it's ready at its time: due 10 minutes before, not 30.
    let mut soon = d.clone();
    soon.schedule.minute = ((now + 10 * minute).rem_euclid(86_400_000) / minute) as u32;
    core.update_show(s.id.clone(), soon.clone()).unwrap();
    let due = core.due_shows(now, 0).unwrap();
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].slot_ms, now + 10 * minute - (now + 10 * minute).rem_euclid(minute));
    soon.schedule.minute = ((now + 30 * minute).rem_euclid(86_400_000) / minute) as u32;
    core.update_show(s.id.clone(), soon).unwrap();
    let slot = now + 30 * minute - (now + 30 * minute).rem_euclid(minute);
    assert!(core.due_shows(now, 0).unwrap().is_empty());
    assert_eq!(core.next_show_slot(now, 0).unwrap(), Some(slot - 20 * minute));
    assert_eq!(core.show_next_slot(s.id.clone(), now, 0).unwrap(), Some(slot));
    core.update_show(s.id.clone(), d.clone()).unwrap();
    // Written by another device: not this one's to write.
    let mut other = d.clone();
    other.device = Some("someone-else".into());
    core.update_show(s.id.clone(), other).unwrap();
    assert!(core.due_shows(now, 0).unwrap().is_empty());
    assert_eq!(core.next_show_slot(now, 0).unwrap(), None);
}

/// An episode written on the Mac reaches the phone as its file (同步 · 书文件), and comes out
/// the same episode there, not a TXT of its script.
#[test]
fn an_episode_travels_as_its_file() {
    let mac = YuyueCore::open(temp("ep-mac"), "Mac".into(), "macos".into()).unwrap();
    let phone = YuyueCore::open(temp("ep-phone"), "iPhone".into(), "ios".into()).unwrap();
    let s = show(&mac);
    let script = parse_script(answer(), s.clone(), articles()).unwrap();
    let e = mac.save_episode(s.id.clone(), "2026-11-01".into(), script).unwrap();
    phone.import_changes(mac.export_changes(phone.sync_version().unwrap()).unwrap()).unwrap();
    assert!(!phone.summary(&e.book).unwrap().available);

    let file = mac.original_file(e.book.clone()).unwrap();
    let copy = std::path::Path::new(&temp("ep-copy")).join(format!("{}.podcast", e.book));
    std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
    std::fs::copy(&file, &copy).unwrap();
    let b = phone.import_book(copy.to_string_lossy().into_owned()).unwrap();
    assert_eq!(b.id, e.book);
    assert_eq!(b.format, BookFormat::Podcast);
    assert!(b.available);
    assert_eq!(phone.sentences(e.book.clone(), 0).unwrap(), mac.sentences(e.book.clone(), 0).unwrap());
    assert_eq!(phone.section_speakers(e.book.clone(), 0).unwrap(), mac.section_speakers(e.book, 0).unwrap());
}

/// The 播放条 and the 节目单 know where each 条 starts: the segments, in order, cover the
/// script's lines and nothing before the first (the title and summary).
#[test]
fn an_episode_knows_its_segments() {
    let core = YuyueCore::open(temp("ep-segs"), "Mac".into(), "macos".into()).unwrap();
    let s = show(&core);
    let script = parse_script(answer(), s.clone(), articles()).unwrap();
    let n = script.segments.len();
    let e = core.save_episode(s.id.clone(), "2026-11-01".into(), script.clone()).unwrap();
    let segs = core.episode_segments(e.book.clone()).unwrap();
    assert_eq!(segs.len(), n);
    let speakers = core.section_speakers(e.book.clone(), 0).unwrap();
    // The first sentence of the first 条 is the first a host says (its topic line has no speaker).
    assert!(speakers[..segs[0].first as usize].iter().all(|w| w.is_none()) || segs[0].first > 0);
    for (seg, g) in segs.iter().zip(&script.segments) {
        assert_eq!(seg.topic, g.topic);
        assert_eq!(seg.articles, g.articles);
        assert!(seg.first <= seg.last && seg.units > 0);
    }
    for w in segs.windows(2) {
        assert!(w[0].last < w[1].first);
    }
    assert_eq!(segs.last().unwrap().last as usize, speakers.len() - 1);
    // A book has none.
    assert!(core.episode_segments("nope".into()).is_err() || core.episode_segments("nope".into()).unwrap().is_empty());
}
