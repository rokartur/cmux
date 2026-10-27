//! Idle retirement must spare both same-group and escaped, unreported work.
use super::*;

async fn idle(hub: &Hub, session: &acpmux::hub::Session) {
    let mut events = hub.subscribe();
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if session.meta().status == acpmux::store::SessionStatus::Idle {
                break;
            }
            events.recv().await.unwrap();
        }
    })
    .await
    .expect("idle retirement completed");
}

struct Children(std::path::PathBuf);
impl Drop for Children {
    fn drop(&mut self) {
        // These exact PIDs were spawned only by this test's fake harness.
        if let Ok(text) = std::fs::read_to_string(&self.0) {
            for line in text.lines() {
                for pid in serde_json::from_str::<Vec<i32>>(line).unwrap() {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                    }
                }
            }
        }
        let _ = std::fs::remove_file(&self.0);
    }
}

#[tokio::test]
async fn idle_pid_only_preserves_same_group_and_escaped_children_then_wakes() {
    let root = std::env::temp_dir().join(format!("idle-owned-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let children = Children(root.join("children"));
    let probe = tokio::net::UnixDatagram::bind(root.join("probe")).unwrap();
    let (hub, mut c) = stop::claude_setup_env(BTreeMap::from([
        ("FAKE_CLAUDE_IDLE_CHILDREN".into(), children.0.to_string_lossy().into_owned()),
        ("FAKE_CLAUDE_STORE".into(), root.to_string_lossy().into_owned()),
        ("FAKE_CLAUDE_IDLE_PROBE_SOCKET".into(), root.join("probe").to_string_lossy().into_owned()),
    ]))
    .await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(2)));
    let made =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type":"text", "text":"before"}]}),
    )
    .await
    .unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let session = hub.resolve(id).unwrap();
    let agent = session.meta().agent_session_id;
    let pids: Vec<i32> =
        serde_json::from_str(std::fs::read_to_string(&children.0).unwrap().lines().next().unwrap())
            .unwrap();
    clock.advance(Duration::from_secs(3));
    idle(&hub, &session).await;
    // Cover the existing reader's 500ms leader check too, not only the TERM path.
    tokio::time::sleep(Duration::from_millis(700)).await;
    for pid in pids {
        assert_eq!(unsafe { libc::kill(pid, libc::SIGUSR1) }, 0);
        let mut reply = [0; 32];
        let n = tokio::time::timeout(Duration::from_secs(3), probe.recv(&mut reply))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(std::str::from_utf8(&reply[..n]).unwrap(), pid.to_string());
    }
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type":"text", "text":"after"}]}),
    )
    .await
    .unwrap();
    assert_eq!(session.meta().agent_session_id, agent);
    assert!(hub.events(id, 0, 1000).unwrap().iter().any(|e| e.kind == "resumed"));
    hub.shutdown_all().await;
    drop(children);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn idle_pid_only_does_not_retire_an_inflight_config_request() {
    let (hub, mut c) = stop::claude_setup_env(BTreeMap::from([(
        "FAKE_CLAUDE_MODE_DELAY_MS".into(),
        "1500".into(),
    )]))
    .await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(2)));
    let made =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let session = hub.resolve(id).unwrap();
    let mut events = hub.subscribe();
    let changing = {
        let hub = hub.clone();
        let session = session.clone();
        tokio::spawn(async move {
            hub.forward(&session, method::SESSION_SET_MODE, json!({"modeId":"plan"})).await
        })
    };
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if hub
                .events(id, 0, 1000)
                .unwrap()
                .iter()
                .any(|e| e.dir == "out" && e.kind == method::SESSION_SET_MODE)
            {
                break;
            }
            events.recv().await.unwrap();
        }
    })
    .await
    .unwrap();
    clock.advance(Duration::from_secs(3));
    assert!(changing.await.unwrap().is_ok(), "idle killed an in-flight config request");
    hub.shutdown_all().await;
}
