use crate::database::DB;
use crate::entity::is_db_alive;
use crate::events::event::Event;
use crate::rauthy_config::RauthyConfig;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tracing::debug;

/// Whether the storage layer was confirmed reachable at the last health tick.
///
/// Read by the `/ready` handler. It starts `true` so that the readiness probe keeps answering
/// during the startup window, before the watcher below has taken its first sample; from then on it
/// is the watcher's confirmed verdict, which is only recorded after a failed probe has been
/// re-checked, so a leader change does not flap a node out of service.
static STORAGE_READY: AtomicBool = AtomicBool::new(true);

/// Whether this node's storage layer is ready to serve.
#[inline]
pub fn storage_ready() -> bool {
    STORAGE_READY.load(Ordering::Relaxed)
}

pub async fn watch_health() {
    debug!("Rauthy health watcher started");

    // Rolling releases can take quite a while in some environments.
    // We don't want false-positive notifications during these.
    tokio::time::sleep(Duration::from_secs(60)).await;

    let mut interval = tokio::time::interval(Duration::from_secs(30));
    let mut was_healthy_after_startup = false;
    let mut last_state = false;
    let tx_events = RauthyConfig::get().tx_events.clone();

    loop {
        interval.tick().await;

        let cache_healthy = DB::hql().is_healthy_cache().await.is_ok();

        let db_alive = if is_db_alive().await {
            true
        } else {
            // A single failed probe can be nothing worse than a leader change. Confirm it before
            // acting on it, so that neither the event nor the readiness verdict flaps.
            tokio::time::sleep(Duration::from_secs(10)).await;
            is_db_alive().await
        };

        let is_good_now = db_alive && cache_healthy;

        // This is what `/ready` answers with. It is recorded even before the first healthy tick:
        // a node whose storage never came up must not keep reporting itself ready.
        STORAGE_READY.store(is_good_now, Ordering::Relaxed);

        // Only alert about a database that was working at some point. A node that has not
        // finished starting up is not news.
        if !db_alive && was_healthy_after_startup {
            tx_events
                .send_async(Event::rauthy_unhealthy_db())
                .await
                .unwrap();
        }
        if !was_healthy_after_startup && is_good_now {
            was_healthy_after_startup = true;
        }

        if is_good_now && !last_state {
            // let only the cache leader send healthy message in HA deployment
            tx_events.send_async(Event::rauthy_healthy()).await.unwrap();
        }

        last_state = is_good_now;
    }
}
