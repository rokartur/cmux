//! The held child's owner owns retirement and cancels its deadline on exit.
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

pub(super) struct Request {
    pub generation: u64,
    pub grace: std::time::Duration,
    pub expires: tokio::time::Instant,
    pub accepted: tokio::sync::oneshot::Sender<bool>,
}

pub(super) async fn wait(
    mut child: tokio::process::Child,
    pid_only: Arc<AtomicBool>,
    activity: Arc<AtomicU64>,
    mut stop: tokio::sync::mpsc::Receiver<Request>,
) -> Option<i32> {
    let Some(pid) = child.id().map(|p| p as i32) else { return None };
    let mut exited = tokio::task::spawn_blocking(move || super::host::wait_exit_unreaped(pid));
    let proof = loop {
        tokio::select! {
            result = &mut exited => break result.is_ok_and(|exited| exited),
            Some(request) = stop.recv() => {
                if request.expires <= tokio::time::Instant::now()
                    || activity.load(Ordering::SeqCst) != request.generation
                {
                    let _ = request.accepted.send(false);
                    continue;
                }
                // No await between fence and signal; this owner has not reaped the child.
                pid_only.store(true, Ordering::SeqCst);
                unsafe { libc::kill(pid, libc::SIGTERM); }
                let _ = request.accepted.send(true);
                let result = match tokio::time::timeout(request.grace.min(std::time::Duration::from_secs(1)), &mut exited).await {
                    Ok(result) => result,
                    Err(_) => {
                        unsafe { libc::kill(pid, libc::SIGKILL); }
                        exited.await
                    }
                };
                break result.is_ok_and(|exited| exited);
            }
        }
    };
    if proof && !pid_only.load(Ordering::SeqCst) {
        // Ordinary exit retains its existing cleanup only with positive unreaped-child proof.
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    }
    child.wait().await.ok().and_then(|status| status.code())
}

#[cfg(test)]
#[path = "hibernate_tests.rs"]
mod tests;
