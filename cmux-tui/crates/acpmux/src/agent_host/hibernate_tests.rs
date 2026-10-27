use super::*;
use tokio::io::{AsyncBufReadExt, BufReader};

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
async fn idle_pid_only_host_owner_fences_activity_and_spares_every_grandchild() {
    let script = r#"import json, subprocess, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pids = [subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)'], start_new_session=s, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid for s in (False, True)]
print(json.dumps(pids), flush=True)
time.sleep(600)
"#;
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
    let children = Children(serde_json::from_str(&line).unwrap());
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
    for pid in &children.0 {
        assert_eq!(unsafe { libc::kill(*pid, 0) }, 0, "grandchild was signalled");
    }
}
