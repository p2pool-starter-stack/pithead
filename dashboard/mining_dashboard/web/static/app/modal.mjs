// Shared modal dialog (#1876): the "native platform feature over JS state" call Worker Inspect's
// own <dialog> already made (#518, workerview.mjs). showModal() gives focus-trapping, Escape, and
// focus-return-to-opener for free; ::backdrop replaces a hand-rolled overlay div.
//
// `onCancel` fires on the dialog's `cancel` event (Escape) and is the same handler callers wire to
// their Cancel/Close button. The default is ALWAYS prevented, so refusing a cancel (an upgrade or
// backup in flight) is just not acting on it, and closing means calling close() from inside
// `onCancel` — which fires the native `close` event and returns focus to the opener on its own.
import { Component, createRef, html } from "./preact.mjs";

export class Modal extends Component {
  constructor(props) {
    super(props);
    this.dialogRef = createRef();
    this.titleRef = createRef();
  }

  componentDidMount() {
    this.dialogRef.current?.showModal();
    this.titleRef.current?.focus();
  }

  close() {
    this.dialogRef.current?.close();
  }

  // A parent can drop the modal without cancelling it: a commit lands, a backup finishes, and the
  // phase it switches to renders something else entirely. Removing an OPEN <dialog> from the DOM
  // never runs the spec's close-the-dialog steps, and focus-return-to-opener lives in those steps
  // — focus would fall to <body>, the very bug #1876 is about. So close it on the way out, with
  // `onClose` suppressed: that callback exists to tell a still-mounted parent to change phase, and
  // here the parent has already changed it (ConfigView would bounce "done" back to "form").
  componentWillUnmount() {
    this.unmounting = true;
    this.dialogRef.current?.close();
  }

  render() {
    const { title, onCancel, onClose, children } = this.props;
    return html`
      <dialog class="card config-modal" ref=${this.dialogRef} role="dialog" aria-modal="true"
              aria-label=${title} onCancel=${(e) => {
                e.preventDefault();
                onCancel?.();
              }} onClose=${(e) => !this.unmounting && onClose?.(e)}>
        <h2 tabindex="-1" ref=${this.titleRef}>${title}</h2>
        ${children}
      </dialog>`;
  }
}
