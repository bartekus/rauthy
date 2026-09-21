use crate::database::DB;
use crate::entity::config::ConfigEntity;
use hiqlite::macros::params;
use rauthy_common::constants::{RAUTHY_UPSTREAM_BASE, RAUTHY_VERSION};
use rauthy_common::is_hiqlite;
use rauthy_common::utils::{deserialize, serialize};
use rauthy_error::ErrorResponse;
use semver::Version;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use tracing::{debug, info, warn};

// TODO After bumping to v0.37, make sure the lowest compatible is set to v0.36
//  and `apply_temp_migrations()` was cleaned up!
static LOWEST_COMPATIBLE_VERSION: &str = "0.35.0";

#[derive(Debug, Serialize, Deserialize)]
pub struct DbVersion {
    pub version: Version,
}

impl DbVersion {
    pub async fn find() -> Option<Self> {
        let sql = "SELECT * FROM config WHERE id = 'db_version'";
        let bytes: Vec<u8> = if is_hiqlite() {
            let config: ConfigEntity = DB::hql().query_as_optional(sql, params!()).await.ok()??;
            config.data
        } else {
            let config: ConfigEntity = DB::pg_query_opt(sql, &[]).await.ok()??;
            config.data
        };

        deserialize::<Self>(&bytes).ok()
    }

    pub async fn upsert(db_version: Option<Version>) -> Result<(), ErrorResponse> {
        let app_version = Self::app_version();
        if Some(&app_version) != db_version.as_ref() {
            let slf = Self {
                version: app_version,
            };
            let data = serialize(&slf)?;

            let sql = r#"
INSERT INTO config (id, data)
VALUES ('db_version', $1)
ON CONFLICT(id) DO UPDATE SET data = $1"#;

            if is_hiqlite() {
                DB::hql().execute(sql, params!(data)).await?;
            } else {
                DB::pg_execute(sql, &[&data]).await?;
            }
        }

        Ok(())
    }

    pub async fn check_app_version() -> Result<Option<Version>, ErrorResponse> {
        let app_version = Self::app_version();
        debug!("Current Rauthy Version: {app_version:?}");

        // check DB version for compatibility
        // We check the `config` table first instead of db version, because the db version does not
        // exist in early versions while the `config` does from the very beginning.
        let sql = "SELECT id FROM config LIMIT 1";
        let db_exists = if is_hiqlite() {
            DB::hql().query_raw(sql, params!()).await.is_ok()
        } else {
            DB::pg_query_one_row(sql, &[]).await.is_ok()
        };

        if !db_exists {
            return Ok(None);
        }

        let db_version = match Self::find().await {
            None => {
                debug!("No Current DB Version found");
                Self::is_db_compatible(&app_version, None).await?;
                None
            }
            Some(db_version) => {
                debug!("Current DB Version: {:?}", db_version);
                Self::is_db_compatible(&app_version, Some(&db_version.version)).await?;
                Some(db_version.version)
            }
        };

        Ok(db_version)
    }

    /// Checks if we can use an existing (possibly older) db with this version of rauthy, or if
    /// the user may need to take action beforehand.
    async fn is_db_compatible(
        app_version: &Version,
        db_version: Option<&Version>,
    ) -> Result<(), ErrorResponse> {
        // this check panics on purpose, and it is there to never forget to adjust this
        // version check before doing any major or minor release
        // TODO After bumping to v0.37, make sure the lowest compatible is set to v0.36
        //  and `apply_temp_migrations()` was cleaned up!
        if app_version.major != 0 || app_version.minor != 36 {
            panic!(
                "\nDbVersion::check_app_version needs adjustment for the new RAUTHY_VERSION: \
                {RAUTHY_VERSION}\\n Also make sure that `LOWEST_COMPATIBLE_VERSION` is still \
                correctly set",
            );
        }

        // A downstream patched build carries its distribution marker in the SemVer pre-release
        // field, because that is the only place a valid SemVer can hold it and still parse and
        // order. It is not an upstream pre-release, so it does not get the pre-release warning;
        // anything else in that field still does.
        match downstream_patch_level(app_version) {
            Some(level) => {
                info!(
                    "Downstream patched build {level} of upstream Rauthy {RAUTHY_UPSTREAM_BASE}. \
                    This is not an upstream release.",
                );
            }
            None if !app_version.pre.is_empty() => {
                warn!(
                    "!!! Caution: you are using a pre-release version: {} - DO NOT USE IN PRODUCTION !!!",
                    app_version.pre.as_str()
                );
            }
            None => {}
        }

        // check for the lowest DB version we can use with this App Version
        if let Some(db_version) = db_version {
            let lowest_compatible_version = Version::parse(LOWEST_COMPATIBLE_VERSION).unwrap();

            if db_version < &lowest_compatible_version {
                panic!(
                    "Your database is too old for this upgrade.\n\
                    Rauthy {app_version} needs at least a DB version {lowest_compatible_version}\n\
                    Please check https://github.com/sebadob/rauthy/releases for additional \
                    information.",
                );
            }

            return Ok(());
        }

        // check the DB version in another way if we did not find an existing DB version

        // from v0.16.0 on we did have the db_version inside the `config` table,
        // which is already checked above

        // the passkeys table was introduced with v0.15.0
        let is_db_v0_15_0 = if is_hiqlite() {
            DB::hql().query_raw("SELECT * FROM sqlite_master WHERE type = 'table' AND name = 'passkeys' LIMIT 1", params!()).await.is_err()
        } else {
            DB::pg_query_one_row(
                "SELECT * FROM pg_tables WHERE tablename = 'passkeys' LIMIT 1",
                &[],
            )
            .await
            .is_err()
        };
        if is_db_v0_15_0 {
            panic!(
                "Your database is Rauthy v0.15.0. You need to upgrade to Rauthy v0.16 first.\n\
                Please check https://github.com/sebadob/rauthy/releases for additional information."
            );
        }

        // To check for any DB older than 0.15.0, we check for the existence of the 'clients' table
        // which is there since the very beginning.
        let is_db_pre_v0_15_0 = if is_hiqlite() {
            DB::hql()
                .query_raw(
                    "SELECT * FROM sqlite_master WHERE type = 'table' AND name = 'clients' LIMIT 1",
                    params!(),
                )
                .await
                .is_err()
        } else {
            DB::pg_query_one_row(
                "SELECT * FROM pg_tables WHERE tablename = 'clients' LIMIT 1",
                &[],
            )
            .await
            .is_err()
        };
        if is_db_pre_v0_15_0 {
            panic!(
                "Your database is older than Rauthy v0.15.0. You need to upgrade to Rauthy v0.15 first.\n\
                Please check https://github.com/sebadob/rauthy/releases for additional information."
            );
        }

        // Since we did not find the clients table, we can assume, that the DB is really empty.
        Ok(())
    }
}

impl DbVersion {
    pub fn app_version() -> Version {
        Version::from_str(RAUTHY_VERSION).expect("bad format for RAUTHY_VERSION")
    }
}

/// The patch level of a downstream build, if this version is one.
///
/// The marker is `patched.<n>` in the SemVer pre-release field, so `0.36.2-patched.1` is the first
/// patched build of upstream `0.36.2`. Anything else in that field is a real pre-release.
fn downstream_patch_level(version: &Version) -> Option<u32> {
    version.pre.as_str().strip_prefix("patched.")?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_version_parses_and_is_recognised_as_a_downstream_build() {
        let v = DbVersion::app_version();
        assert_eq!((v.major, v.minor), (0, 36), "the guard below keys on this");
        assert_eq!(
            downstream_patch_level(&v),
            Some(1),
            "RAUTHY_VERSION {RAUTHY_VERSION} must carry the downstream marker, or the release \
            would log an upstream pre-release warning"
        );
    }

    #[test]
    fn a_real_prerelease_is_not_mistaken_for_a_downstream_build() {
        for raw in ["0.37.0-20260917", "0.36.2-rc.1", "0.36.2", "0.36.2-patched"] {
            assert_eq!(
                downstream_patch_level(&Version::parse(raw).unwrap()),
                None,
                "{raw} must keep the upstream pre-release handling"
            );
        }
    }

    /// An operator who rolls back to the upstream release this was built from must not be locked
    /// out by the version this build wrote into the `config` table.
    #[test]
    fn the_version_written_to_the_db_does_not_lock_out_the_upstream_base() {
        let written = DbVersion::app_version();
        let lowest = Version::parse(LOWEST_COMPATIBLE_VERSION).unwrap();
        assert!(
            written >= lowest,
            "upstream {RAUTHY_UPSTREAM_BASE} would refuse a database stamped {written}"
        );
    }
}
