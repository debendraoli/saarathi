//! Photo storage behind a trait so the local dev backend can be swapped for
//! in-country S3/MinIO later. Same shape as `services/auth/src/store.rs`
//! (kept service-local rather than shared — nothing else shares it either).

use async_trait::async_trait;
use std::path::{Path, PathBuf};

#[async_trait]
pub trait DocumentStore: Send + Sync {
    async fn put(&self, key: &str, bytes: Vec<u8>) -> anyhow::Result<()>;
    async fn get(&self, key: &str) -> anyhow::Result<Vec<u8>>;
}

/// Filesystem-backed store for local development.
pub struct LocalDocumentStore {
    root: PathBuf,
}

impl LocalDocumentStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn resolve(&self, key: &str) -> anyhow::Result<PathBuf> {
        // Prevent path traversal: keys are service-generated, but be defensive.
        if key.contains("..") || key.starts_with('/') {
            anyhow::bail!("invalid storage key");
        }
        Ok(self.root.join(key))
    }
}

#[async_trait]
impl DocumentStore for LocalDocumentStore {
    async fn put(&self, key: &str, bytes: Vec<u8>) -> anyhow::Result<()> {
        let path = self.resolve(key)?;
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        tokio::fs::write(&path, bytes).await?;
        Ok(())
    }

    async fn get(&self, key: &str) -> anyhow::Result<Vec<u8>> {
        let path = self.resolve(key)?;
        let bytes = tokio::fs::read(&path).await?;
        Ok(bytes)
    }
}

pub fn ensure_dir(dir: &str) -> anyhow::Result<()> {
    std::fs::create_dir_all(Path::new(dir))?;
    Ok(())
}
