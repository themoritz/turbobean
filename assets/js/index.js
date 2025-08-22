document.addEventListener('alpine:init', () => {
    Alpine.data('app', () => ({
        account: '',
        eventSource: null,

        init() {
            this.initializeFromUrl();
            this.setupPopstateHandler();
            this.setupBeforeUnloadHandler();
        },

        closeExistingConnection() {
            if (this.eventSource) {
                this.eventSource.close();
                this.eventSource = null;
            }
        },

        establishSSEConnection(account, updateUrl = true) {
            this.closeExistingConnection();

            if (updateUrl) {
                const url = new URL(window.location);
                url.pathname = '/journal';
                url.search = `account=${encodeURIComponent(account)}`;
                history.pushState({ account: account }, '', url);
            }

            this.eventSource = new EventSource(`/sse/journal?account=${encodeURIComponent(account)}`);

            this.eventSource.onmessage = (event) => {
                const contentElement = this.$refs.content;
                if (contentElement) {
                    const journal = contentElement.querySelector('.journal');
                    const scrollPos = journal ? journal.scrollTop : 0;
                    contentElement.innerHTML = event.data;
                    const newJournal = contentElement.querySelector('.journal');
                    if (newJournal) {
                        newJournal.scrollTop = scrollPos;
                    }
                }
            };

            this.eventSource.onerror = (event) => {
                console.error('SSE connection error:', event);
                this.closeExistingConnection();
            };
        },

        getAccountFromUrl() {
            const url = new URL(window.location);
            if (url.pathname === '/journal') {
                return url.searchParams.get('account');
            }
            return null;
        },

        initializeFromUrl() {
            const urlAccount = this.getAccountFromUrl();
            if (urlAccount) {
                this.account = urlAccount;
                this.establishSSEConnection(urlAccount, false);
            }
        },

        handleFormSubmit() {
            const accountValue = this.account.trim();
            if (accountValue) {
                this.establishSSEConnection(accountValue);
            }
        },

        setupPopstateHandler() {
            window.addEventListener('popstate', (event) => {
                if (event.state && event.state.account) {
                    this.account = event.state.account;
                    this.establishSSEConnection(event.state.account, false);
                } else {
                    this.closeExistingConnection();
                    this.account = '';
                    this.content = 'Content';
                }
            });
        },

        setupBeforeUnloadHandler() {
            window.addEventListener('beforeunload', () => {
                this.closeExistingConnection();
            });
        }
    }));

    Alpine.store('txOpen', {
        open: localStorage.getItem('txOpen') ? JSON.parse(localStorage.getItem('txOpen')) : {},
        toggle(index) {
            if (this.open[index] === undefined) {
                this.open[index] = false;
            }
            this.open[index] = !this.open[index];
            if (!this.open[index]) {
                delete this.open[index];
            }
            localStorage.setItem('txOpen', JSON.stringify(this.open));
        }
    });
});
