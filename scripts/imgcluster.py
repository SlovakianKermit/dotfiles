#!/usr/bin/env python3
"""
imgcluster.py - Group images by visual style using CLIP + HDBSCAN

Usage:
    imgcluster.py                                   # uses ~/Pictures/img
    imgcluster.py /path/to/folder                   # absolute path
    imgcluster.py Downloads                         # ~/Pictures/img/Downloads
    imgcluster.py /path/to/folder --analyse         # dry run, no files copied
    imgcluster.py /path/to/folder --min-cluster-size 20
    imgcluster.py /path/to/folder --output /path/to/output
"""

import argparse
import sys
import shutil
from pathlib import Path

import numpy as np
from PIL import Image
import torch
from torch.utils.data import Dataset, DataLoader
import open_clip
import hdbscan
import umap
from tqdm import tqdm


# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_INPUT   = Path.home() / "Pictures" / "img"
DEFAULT_OUTPUT  = None          # defaults to <input_dir>/clustered

# WD ViT-Large — trained on danbooru, excellent for anime/AI-generated art
MODEL_NAME      = "ViT-L-14"
MODEL_PRETRAINED = "datacomp_xl_s13b_b90k"  # best general ViT-L-14 in open_clip

BATCH_SIZE      = 128           # lower if you hit OOM
NUM_WORKERS     = 4             # parallel CPU image loading
IMAGE_EXTS      = {".webp", ".jpg", ".jpeg", ".png"}

# HDBSCAN defaults
DEFAULT_MIN_CLUSTER_SIZE = 10
DEFAULT_MIN_SAMPLES      = 3


# ── Dataset ───────────────────────────────────────────────────────────────────

class ImageDataset(Dataset):
    def __init__(self, paths: list[Path], transform):
        self.paths = paths
        self.transform = transform

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, idx):
        p = self.paths[idx]
        try:
            img = Image.open(p).convert("RGB")
            return self.transform(img), idx
        except Exception:
            # return a blank image on failure so the batch stays aligned
            blank = Image.new("RGB", (224, 224), (0, 0, 0))
            return self.transform(blank), idx


# ── Helpers ───────────────────────────────────────────────────────────────────

def find_images(root: Path) -> list[Path]:
    images = []
    for p in root.rglob("*"):
        if p.suffix.lower() in IMAGE_EXTS:
            images.append(p)
    return sorted(images)


def embed_images(paths: list[Path], model, transform, device) -> np.ndarray:
    dataset = ImageDataset(paths, transform)
    loader  = DataLoader(
        dataset,
        batch_size=BATCH_SIZE,
        num_workers=NUM_WORKERS,
        pin_memory=(device == "cuda"),
        prefetch_factor=2,
    )

    embeddings = np.zeros((len(paths), 768), dtype=np.float32)  # ViT-L-14 = 768 dims

    with torch.no_grad():
        for images, indices in tqdm(loader, desc="Embedding images"):
            images = images.to(device, non_blocking=True)
            features = model.encode_image(images)
            features = features / features.norm(dim=-1, keepdim=True)
            embeddings[indices.numpy()] = features.cpu().float().numpy()

    return embeddings


def reduce_embeddings(embeddings: np.ndarray, n_components: int = 50) -> np.ndarray:
    print(f"Reducing {embeddings.shape[1]}d embeddings to {n_components}d with UMAP...")
    reducer = umap.UMAP(
        n_components=n_components,
        n_neighbors=15,
        min_dist=0.0,       # tighter clusters, better for HDBSCAN
        metric="cosine",
        random_state=42,
        verbose=False,
    )
    return reducer.fit_transform(embeddings)


def cluster_embeddings(embeddings: np.ndarray, min_cluster_size: int, min_samples: int):
    clusterer = hdbscan.HDBSCAN(
        min_cluster_size=min_cluster_size,
        min_samples=min_samples,
        metric="euclidean",
        cluster_selection_method="leaf",  # finer-grained than eom
    )
    return clusterer.fit_predict(embeddings)


def print_cluster_summary(labels: np.ndarray, paths: list[Path]):
    unique       = sorted(set(labels))
    noise_count  = int(np.sum(labels == -1))
    cluster_ids  = [l for l in unique if l != -1]

    print()
    print("=" * 50)
    print(f"  Found {len(cluster_ids)} style cluster(s)")
    print("=" * 50)
    for cid in cluster_ids:
        count = int(np.sum(labels == cid))
        print(f"  Cluster {cid + 1:>3}:  {count:>5} images")
    if noise_count:
        print(f"  Uncategorised:  {noise_count:>5} images")
    print("=" * 50)
    print(f"  Total:          {len(paths):>5} images")
    print()


def copy_to_clusters(labels: np.ndarray, paths: list[Path], output_dir: Path):
    unique      = sorted(set(labels))
    cluster_ids = [l for l in unique if l != -1]

    output_dir.mkdir(parents=True, exist_ok=True)
    for cid in cluster_ids:
        (output_dir / f"style_{cid + 1:02d}").mkdir(exist_ok=True)
    if -1 in unique:
        (output_dir / "uncategorised").mkdir(exist_ok=True)

    print(f"Copying files to: {output_dir}")
    for label, path in tqdm(zip(labels, paths), total=len(paths), desc="Copying"):
        dest_dir = output_dir / ("uncategorised" if label == -1 else f"style_{label + 1:02d}")
        dest     = dest_dir / path.name
        if dest.exists():
            dest = dest_dir / f"{path.stem}_{path.parent.name}{path.suffix}"
        shutil.copy2(path, dest)

    print("Done. Originals are untouched.")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Group images by visual style using CLIP + HDBSCAN"
    )
    parser.add_argument(
        "input",
        nargs="?",
        type=Path,
        default=DEFAULT_INPUT,
        help=f"Input folder (default: {DEFAULT_INPUT})",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=None,
        help="Output folder (default: <input>/clustered)",
    )
    parser.add_argument(
        "--analyse", "-a",
        action="store_true",
        help="Dry run: print cluster counts only, do not copy files",
    )
    parser.add_argument(
        "--min-cluster-size",
        type=int,
        default=DEFAULT_MIN_CLUSTER_SIZE,
        help=f"Min images per cluster (default: {DEFAULT_MIN_CLUSTER_SIZE}). "
             "Raise for fewer broader groups, lower for finer splits.",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=DEFAULT_MIN_SAMPLES,
        help=f"HDBSCAN min_samples (default: {DEFAULT_MIN_SAMPLES}). "
             "Raise to push ambiguous images into uncategorised.",
    )

    args = parser.parse_args()

    raw = args.input
    if raw == DEFAULT_INPUT:
        input_dir = DEFAULT_INPUT.expanduser().resolve()
    elif raw.is_absolute():
        input_dir = raw.expanduser().resolve()
    else:
        input_dir = (DEFAULT_INPUT.expanduser() / raw).resolve()

    if not input_dir.exists():
        print(f"Error: path does not exist: {input_dir}")
        sys.exit(1)

    output_dir = args.output or (input_dir / "clustered")

    # ── Find images ───────────────────────────────────────────────────────────
    print(f"Scanning: {input_dir}")
    paths = find_images(input_dir)
    if not paths:
        print("No images found.")
        sys.exit(0)
    print(f"Found {len(paths)} image(s)")

    # ── Load model ────────────────────────────────────────────────────────────
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Loading {MODEL_NAME} ({MODEL_PRETRAINED}) on {device}...")

    model, _, transform = open_clip.create_model_and_transforms(
        MODEL_NAME,
        pretrained=MODEL_PRETRAINED,
        device=device,
    )
    model.eval()

    # ── Embed ─────────────────────────────────────────────────────────────────
    embeddings = embed_images(paths, model, transform, device)

    del model
    if device == "cuda":
        torch.cuda.empty_cache()

    # ── Cluster ───────────────────────────────────────────────────────────────
    reduced = reduce_embeddings(embeddings)
    print("Clustering...")
    labels = cluster_embeddings(reduced, args.min_cluster_size, args.min_samples)

    print_cluster_summary(labels, paths)

    if args.analyse:
        print("Analyse mode: no files were copied.")
        print("Re-run without --analyse to sort, or adjust --min-cluster-size first.")
        return

    # ── Copy ──────────────────────────────────────────────────────────────────
    copy_to_clusters(labels, paths, output_dir)


if __name__ == "__main__":
    main()
