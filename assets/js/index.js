document.addEventListener('alpine:init', () => {
    Alpine.data('app', () => ({
        account: '',
        startDate: '',
        endDate: '',
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
                const params = new URLSearchParams();
                params.set('account', account);
                if (this.startDate) params.set('startDate', this.startDate);
                if (this.endDate) params.set('endDate', this.endDate);
                url.search = params.toString();
                history.pushState({ account: account, startDate: this.startDate, endDate: this.endDate }, '', url);
            }

            const params = new URLSearchParams();
            params.set('account', account);
            if (this.startDate) params.set('startDate', this.startDate);
            if (this.endDate) params.set('endDate', this.endDate);
            this.eventSource = new EventSource(`/sse/journal?${params.toString()}`);

            this.eventSource.onmessage = (event) => {
                const contentElement = this.$refs.content;
                console.log(event);
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

            this.eventSource.addEventListener('plot_points', (event) => {
                console.log(event);
            })

            this.eventSource.onerror = (event) => {
                console.error('SSE connection error:', event);
                this.closeExistingConnection();
            };
        },

        getAccountFromUrl() {
            const url = new URL(window.location);
            if (url.pathname === '/journal') {
                return {
                    account: url.searchParams.get('account'),
                    startDate: url.searchParams.get('startDate') || '',
                    endDate: url.searchParams.get('endDate') || ''
                };
            }
            return null;
        },

        initializeFromUrl() {
            const urlParams = this.getAccountFromUrl();
            if (urlParams && urlParams.account) {
                this.account = urlParams.account;
                this.startDate = urlParams.startDate;
                this.endDate = urlParams.endDate;
                this.establishSSEConnection(urlParams.account, false);
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
                    this.startDate = event.state.startDate || '';
                    this.endDate = event.state.endDate || '';
                    this.establishSSEConnection(event.state.account, false);
                } else {
                    this.closeExistingConnection();
                    this.account = '';
                    this.startDate = '';
                    this.endDate = '';
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
