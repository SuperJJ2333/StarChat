// Customer-service orders use the live management session. Each server action
// rechecks identity, role and order ownership; no wallet password/grant UI.
export function supportOrderAccessPanel(api,{renderContent}={}) {
  return renderContent(api);
}
