// Side-effect CSS imports from third-party packages (e.g. leaflet/dist/leaflet.css)
// aren't covered by Next.js's built-in CSS module types, which only cover
// *.module.css. Webpack/Next handles the actual import at build time; this
// just satisfies the type-checker.
declare module "*.css";
