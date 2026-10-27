use super::*;

struct Children(Vec<i32>);
impl Drop for Children {
    fn drop(&mut self) {
        for pid in &self.0 {
            unsafe {
                libc::kill(*pid, libc::SIGKILL);
            }
        }
    }
}

#[tokio::test]
async fn idle_pid_only_host_query_fences_activity_and_preserves_children() {
    let dir = scratch("idle");
    let probe = tokio::net::UnixDatagram::bind(dir.join("probe")).unwrap();
    let mut launch = spec(&dir, "idle");
    launch.env.push((
        "FAKE_CLAUDE_IDLE_PROBE_SOCKET".into(),
        dir.join("probe").to_string_lossy().into_owned(),
    ));
    launch.args = vec![concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py").into()];
    launch.env.push((
        "FAKE_CLAUDE_IDLE_CHILDREN".into(),
        dir.join("children").to_string_lossy().into_owned(),
    ));
    launch.translator = Some(agent_host::TranslatorSpec {
        acp_session_id: "idle".into(),
        mode: "default".into(),
        model: "default".into(),
        effort: "default".into(),
        fast: false,
        claude_session_id: None,
    });
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    let death = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut h = 0;
    request(&owner, 1, "initialize", json!({"protocolVersion":1})).await;
    read_until(&owner, &mut h, |e| is_response(e, 1)).await;
    let children = Children(
        serde_json::from_str(
            std::fs::read_to_string(dir.join("children")).unwrap().lines().next().unwrap(),
        )
        .unwrap(),
    );
    let stale = owner.query().await.unwrap().idle_generation.unwrap();
    request(&owner, 2, "session/new", json!({"cwd":dir,"mcpServers":[]})).await;
    read_until(&owner, &mut h, |e| is_response(e, 2)).await;
    assert!(!owner.hibernate(stale, Duration::from_millis(20)).await.unwrap());
    let current = owner.query().await.unwrap().idle_generation.unwrap();
    assert!(owner.hibernate(current, Duration::from_millis(20)).await.unwrap());
    read_until(&owner, &mut h, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(death).await;
    for pid in &children.0 {
        assert_eq!(unsafe { libc::kill(*pid, libc::SIGUSR1) }, 0);
        let mut reply = [0; 32];
        let n = tokio::time::timeout(Duration::from_secs(3), probe.recv(&mut reply))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(std::str::from_utf8(&reply[..n]).unwrap(), pid.to_string());
    }
    drop(children);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn idle_pid_only_unknown_reporter_and_old_query_have_no_capability() {
    let old: HostFrame = serde_json::from_value(json!({"t":"query_reply", "id":1,
        "claude_session_id":null,"modes":null,"config_options":null}))
    .unwrap();
    assert!(matches!(old, HostFrame::QueryReply { idle_generation: None, .. }));
    let dir = scratch("opaque");
    let record = link::spawn(&launcher(), &spec(&dir, "opaque")).await.unwrap();
    let death = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    assert!(owner.query().await.unwrap().idle_generation.is_none());
    owner.terminate(Duration::from_millis(20)).await.unwrap();
    let mut h = 0;
    read_until(&owner, &mut h, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(death).await;
    let _ = std::fs::remove_dir_all(dir);
}
