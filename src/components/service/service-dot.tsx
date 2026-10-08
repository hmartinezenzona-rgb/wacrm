import { serviceColor, serviceDotClass } from "@/lib/service-color";

/** Decorative 8px dot in the fixed colour of a service; always rendered right before the service name. */
export function ServiceDot({ service }: { service: string }) {
  const color = serviceColor(service);
  return (
    <span
      aria-hidden="true"
      data-service={color}
      className={`mr-1.5 inline-block size-2 shrink-0 rounded-full align-middle ${serviceDotClass[color]}`}
    />
  );
}
