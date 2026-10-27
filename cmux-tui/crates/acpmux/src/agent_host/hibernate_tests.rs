use super::*;
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::test]
async fn idle_pid_only_host_owner_fences_activity_and_kills_a_term_resistant_leader() {
    let script = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(600)";
    let mut child = tokio::process::Command::new("python3")
        .args(["-c", script])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let leader = child.id().unwrap() as i32;
    let line = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        BufReader::new(child.stdout.take().unwrap()).lines().next_line(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    assert_eq!(line, "ready");
    let activity = Arc::new(AtomicU64::new(2));
    let pid_only = Arc::new(AtomicBool::new(false));
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let owner = tokio::spawn(wait(child, pid_only.clone(), activity.clone(), rx));
    for (generation, expired) in [(1, false), (2, true)] {
        let (accepted, reply) = tokio::sync::oneshot::channel();
        let now = tokio::time::Instant::now();
        tx.send(Request {
            generation,
            grace: std::time::Duration::from_millis(20),
            expires: if expired { now } else { now + std::time::Duration::from_secs(1) },
            accepted,
        })
        .await
        .unwrap();
        assert!(!reply.await.unwrap(), "stale or expired idle request was accepted");
        assert!(!pid_only.load(Ordering::SeqCst));
        assert_eq!(unsafe { libc::kill(leader, 0) }, 0);
    }
    let (accepted, reply) = tokio::sync::oneshot::channel();
    tx.send(Request {
        generation: 2,
        grace: std::time::Duration::from_millis(20),
        expires: tokio::time::Instant::now() + std::time::Duration::from_secs(1),
        accepted,
    })
    .await
    .unwrap();
    assert!(reply.await.unwrap());
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(5), owner)
            .await
            .unwrap()
            .unwrap()
            .is_none()
    );
    assert!(pid_only.load(Ordering::SeqCst));
    assert_ne!(unsafe { libc::kill(leader, 0) }, 0, "held leader was not reaped");
}
