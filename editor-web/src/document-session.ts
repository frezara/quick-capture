/** Tracks the last acknowledged disk version separately from the live buffer. */
export class DocumentSession {
    savedContent = "";
    private nextID = 0;
    private conflictDisk: string | null = null;
    pendingSave: { id: number; content: string; promise: Promise<boolean>; resolve: (ok: boolean) => void } | null = null;

    constructor(
        private content: () => string,
        private send: (request: { type: string; id: number; content: string; expected: string }) => void,
        private error: (message: string, disk: string | null) => void,
        private saved: () => void,
    ) {}

    acceptDisk(content: string): boolean {
        if (this.content() !== this.savedContent) {
            if (content !== this.savedContent && content !== this.pendingSave?.content) {
                this.conflictDisk = content;
                this.showConflict();
            }
            return false;
        }
        this.useDiskBaseline(content);
        return true;
    }

    useDiskBaseline(content: string) {
        this.savedContent = content;
        this.conflictDisk = null;
    }

    private showConflict() {
        this.error("The file changed elsewhere. Your edits are still here. Choose which version to keep.", this.conflictDisk);
    }

    async save(): Promise<boolean> {
        if (this.pendingSave) {
            if (!await this.pendingSave.promise) return false;
            return this.save();
        }
        if (this.conflictDisk !== null) {
            this.showConflict();
            return false;
        }
        const content = this.content();
        if (content === this.savedContent) return true;
        const id = ++this.nextID;
        let resolve!: (ok: boolean) => void;
        const promise = new Promise<boolean>(done => { resolve = done; });
        this.pendingSave = { id, content, promise, resolve };
        this.send({ type: "save", id, content, expected: this.savedContent });
        if (!await promise) return false;
        // Typing can continue while the native write is in flight. A flush is
        // complete only once the newest buffer has also been acknowledged.
        return this.save();
    }

    acknowledge(id: number, error: string | null, disk: string | null) {
        const request = this.pendingSave;
        if (!request || request.id !== id) return;
        this.pendingSave = null;
        if (error === null) {
            this.savedContent = request.content;
            if (this.conflictDisk !== null && this.conflictDisk !== request.content) {
                this.showConflict();
            } else {
                this.conflictDisk = null;
                this.saved();
            }
        } else {
            this.conflictDisk = disk;
            this.error(error, disk);
        }
        request.resolve(error === null && this.conflictDisk === null);
    }
}
