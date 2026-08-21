//! Shared H3 (resolution-9) primitives — used by both `saarathi-rides` (live
//! driver-location indexing, `dispatch.rs`) and `saarathi-merchant` (geofence
//! polyfill caching, `routes::zone`). Kept together in core so the
//! resolution/ring-sizing logic can't drift between the two services.

use geo::{LineString, Polygon};
use h3o::geom::{ContainmentMode, TilerBuilder};
use h3o::{CellIndex, LatLng, Resolution};

/// City-scale resolution: a good balance of index fan-out vs. precision for
/// both live dispatch and merchant delivery zones (edge length ~174m).
pub const RESOLUTION: Resolution = Resolution::Nine;

pub fn cell_for(lat: f64, lng: f64) -> anyhow::Result<CellIndex> {
    Ok(LatLng::new(lat, lng)?.to_cell(RESOLUTION))
}

/// How many `grid_disk` rings comfortably cover `radius_km` — padded by one
/// ring since the disk's hexagonal boundary isn't the circle we actually want.
pub fn rings_for_radius(radius_km: f64) -> u32 {
    let edge_km = RESOLUTION.edge_length_km();
    ((radius_km / edge_km).ceil() as u32).max(1) + 1
}

/// The H3 resolution-9 cells covering a polygon boundary given as
/// `(lat, lng)` points — the "Polygon→H3 polyfill" primitive merchant
/// geofence caching is built on. `ContainmentMode::Covers` includes any cell
/// that touches the boundary at all (favours over- rather than under-covering
/// a delivery zone — a cell that's mostly outside but clips the edge should
/// still count as "in the zone" for order-visibility purposes).
pub fn polyfill(points: &[(f64, f64)]) -> anyhow::Result<Vec<CellIndex>> {
    if points.len() < 3 {
        anyhow::bail!("a polygon needs at least 3 points");
    }
    // geo's coordinate convention is (x, y) = (lng, lat), matching this
    // codebase's existing PostGIS convention (ST_MakePoint(lng, lat)).
    let coords: Vec<(f64, f64)> = points.iter().map(|(lat, lng)| (*lng, *lat)).collect();
    let polygon = Polygon::new(LineString::from(coords), vec![]);

    let mut tiler = TilerBuilder::new(RESOLUTION)
        .containment_mode(ContainmentMode::Covers)
        .build();
    tiler.add(polygon)?;
    Ok(tiler.into_coverage().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rings_for_radius_covers_at_least_the_requested_distance() {
        let edge_km = RESOLUTION.edge_length_km();
        for radius_km in [0.1, 0.5, 1.0, 2.0, 5.0, 8.0] {
            let k = rings_for_radius(radius_km);
            assert!(
                (k as f64) * edge_km >= radius_km,
                "k={k} edge={edge_km} radius={radius_km}"
            );
        }
    }

    #[test]
    fn cell_for_is_deterministic_and_distinct_points_can_differ() {
        let a = cell_for(28.0336, 82.4836).unwrap();
        let b = cell_for(28.0336, 82.4836).unwrap();
        assert_eq!(a, b);
        let c = cell_for(28.5, 83.0).unwrap();
        assert_ne!(a, c);
    }

    #[test]
    fn polyfill_rejects_degenerate_polygons() {
        assert!(polyfill(&[(28.0, 82.0), (28.01, 82.01)]).is_err());
    }

    #[test]
    fn polyfill_covers_interior_and_excludes_far_points() {
        // A ~1km-ish square around Ghorahi.
        let square = [
            (28.030, 82.480),
            (28.030, 82.490),
            (28.040, 82.490),
            (28.040, 82.480),
        ];
        let cells: std::collections::HashSet<CellIndex> =
            polyfill(&square).unwrap().into_iter().collect();
        assert!(!cells.is_empty());

        let interior = cell_for(28.035, 82.485).unwrap();
        assert!(cells.contains(&interior), "interior point should be covered");

        let far_away = cell_for(28.5, 83.0).unwrap(); // ~50km away
        assert!(
            !cells.contains(&far_away),
            "a point far outside the polygon shouldn't be covered"
        );
    }
}
