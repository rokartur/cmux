//! Idle retirement never enters Stop's group/job/descendant cleanup.
use super::*;

impl ChildAgent {
    pub(crate) fn idle_has_pending(&self) -> bool {
        self.pending.try_lock().map_or(true, |p| !p.map.is_empty())
    }

    pub(crate) async fn idle_generation(&self) -> Option<u64> {
        #[cfg(windows)]
        return None; // Closing a Windows job would end its descendants.
        #[cfg(unix)]
        {
            if let Some(hosted) = &self.hosted {
                return hosted.link().query().await.ok()?.idle_generation;
            }
            let reported = match (&self.translator, &self.codex) {
                (Some(tr), _) => !tr.has_background_work().await,
                (_, Some(cx)) => !cx.tr.has_background_work(),
                _ => false,
            };
            (reported && !self.idle_has_pending())
                .then_some(self.idle_activity.load(Ordering::SeqCst))
        }
    }

    /// True only after the exact held child exited. Lost/old hosts are retained.
    pub(crate) async fn hibernate(&self, generation: u64) -> bool {
        #[cfg(windows)]
        {
            let _ = generation;
            return false;
        }
        #[cfg(unix)]
        {
            if let Some(hosted) = &self.hosted {
                if !hosted.link().hibernate(generation, KILL_GRACE).await.unwrap_or(false) {
                    return false;
                }
                let exited = hosted.exit.notified();
                return tokio::time::timeout(std::time::Duration::from_secs(5), async {
                    if !hosted.exited.load(Ordering::SeqCst) {
                        exited.await;
                    }
                    self.retire();
                    true
                })
                .await
                .unwrap_or(false);
            }
            let mut slot = self.child.lock().await;
            let Some(child) = slot.as_mut() else { return false };
            let Some(pid) = child.id() else { return false };
            if generation != self.idle_activity.load(Ordering::SeqCst) || self.idle_has_pending() {
                return false;
            }
            self.idle_pid_only.store(true, Ordering::SeqCst);
            self.retire();
            // SAFETY: our held, unreaped child, never a group or a cached PID after reaping.
            unsafe {
                libc::kill(pid as i32, libc::SIGTERM);
            }
            match tokio::time::timeout(KILL_GRACE, child.wait()).await {
                Ok(Ok(_)) => {}
                Ok(Err(_)) => return false,
                Err(_) => {
                    let _ = child.start_kill();
                    if !matches!(tokio::time::timeout(KILL_GRACE, child.wait()).await, Ok(Ok(_))) {
                        return false;
                    }
                }
            }
            *slot = None;
            true
        }
    }
}
