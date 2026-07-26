// @ts-nocheck — `@z/site-data` is a build-time virtual module;
// its emitted z-site-data.d.ts types it for real consumer sites.
import site from "@z/site-data";

export interface Props {}

export default function SiteData(_: Props) {
  const first = site.services[0];
  return (
    <p>
      {first.frontmatter.title} / mon {site.hours.mon} / {site.services.length} services
    </p>
  );
}
