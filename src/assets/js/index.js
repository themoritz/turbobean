class Filter {
    constructor() {
        const url = new URL(window.location);
        this.startDate = url.searchParams.get('start_date');
        this.endDate = url.searchParams.get('end_date');

        this.conversion = url.searchParams.get('conversion');
        if (!this.conversion) this.conversion = 'units';
        this.interval = url.searchParams.get('interval');
        if (!this.interval) this.interval = 'week';
    }

    getSearchParams() {
        const params = new URLSearchParams();

        if (this.startDate) params.set('start_date', this.startDate);
        if (this.endDate) params.set('end_date', this.endDate);

        if (this.conversion) params.set('conversion', this.conversion);
        if (this.interval) params.set('interval', this.interval);

        return params;
    }

    getQueryString() {
        const params = this.getSearchParams();
        return params.toString() ? `?${params.toString()}` : '';
    }
}

const Routes = {
    Journal: (account) => ({ type: "Journal", account }),
    BalanceSheet: () => ({ type: "BalanceSheet" }),
    IncomeStatement: () => ({ type: "IncomeStatement" }),
};

class Router {
    constructor() {
        const url = new URL(window.location);
        this.setRoute(url.pathname);
    }

    setRoute(path) {
        const journalMatch = path.match(/^\/journal\/(.+)$/);
        if (journalMatch) {
            this.route = Routes.Journal(decodeURIComponent(journalMatch[1]));
            return;
        }
        if (path.match(/^\/balance_sheet$/)) {
            this.route = Routes.BalanceSheet();
            return
        }
        if (path.match(/^\/income_statement$/)) {
            this.route = Routes.IncomeStatement();
            return
        }
        this.route = null
    }

    generatePathname() {
        switch (this.route.type) {
            case "Journal":
                return `/journal/${this.route.account}`;
            case "BalanceSheet":
                return "/balance_sheet";
            case "IncomeStatement":
                return "/income_statement";
            default:
                return "/";
        }
    }

    getCrumbs() {
        switch (this.route.type) {
            case "Journal":
                return this.route.account;
            case "BalanceSheet":
                return "Balance Sheet";
            case "IncomeStatement":
                return "Income Statement";
            default:
                return "";
        }
    }
}

document.addEventListener('alpine:init', () => {
    initPlotComponent();

    Alpine.data('app', () => ({
        loading: false,
        router: new Router(),
        filter: new Filter(),
        eventSource: null,
        plotData: [],
        plotChanges: [],

        init() {
            if (this.router.route) {
                this.establishSSEConnection(this.router.route);
            }

            window.addEventListener('beforeunload', () => {
                this.closeExistingConnection();
            });

            window.addEventListener('popstate', (_event) => {
                this.router = new Router();
                this.filter = new Filter();
                this.establishSSEConnection();

            });

            this.$watch('filter', (value) => {
                const url = new URL(window.location);
                url.search = value.getQueryString();
                history.pushState({}, '', url);
                this.establishSSEConnection();
            });
        },

        closeExistingConnection() {
            if (this.eventSource) {
                this.eventSource.close();
                this.eventSource = null;
            }
        },

        navigate(path) {
            this.router.setRoute(path);
            const url = new URL(window.location);
            url.pathname = this.router.generatePathname();
            history.pushState({}, '', url);
            this.establishSSEConnection();
        },

        establishSSEConnection() {
            const source = "/sse" + this.router.generatePathname() + this.filter.getQueryString();

            this.closeExistingConnection();
            this.loading = true;
            this.eventSource = new EventSource(source);

            this.eventSource.onmessage = (event) => {
                this.loading = false;
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

            this.eventSource.addEventListener('plot_points', (event) => {
                this.plotData = JSON.parse(event.data);
            })

            this.eventSource.addEventListener('plot_changes', (event) => {
                this.plotChanges = JSON.parse(event.data);
            })

            this.eventSource.onerror = (event) => {
                console.error('SSE connection error:', event);
                this.closeExistingConnection();
            };
        },
    }));

    Alpine.data('nav', (items) => ({
        isOpen: false,
        query: '',
        items: items,
        results: [],
        index: 0,

        open() {
            if (this.isOpen) {
                return;
            }
            this.isOpen = true;
            this.query = '';
            this.search();
        },

        close() {
            this.isOpen = false;
        },

        search() {
            const results = fuzzysort.go(this.query, this.items, {
                all: true,
                key: 'text',
                scoreFn: (r) => r.score * r.obj.weight,
            });

            this.results = results.map((result, i) => ({
                route: result.obj.route,
                html: result.highlight('<mark>', '</mark>'),
                index: i,
            }));

            this.index = 0;
            document.querySelector('.results').scrollTop = 0;
        },

        down() {
            this.index = (this.index + 1) % this.results.length;
            this.scrollIntoView();
        },

        up() {
            this.index = (this.index - 1 + this.results.length) % this.results.length;
            this.scrollIntoView();
        },

        scrollIntoView() {
            const el = document.querySelectorAll('nav .result')[this.index];
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
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

    Alpine.store('accountCollapsed', {
        init() {
            const saved = localStorage.getItem('accountCollapsed');
            if (saved) this.collapsed = new Set(JSON.parse(saved));
            Alpine.effect(() => {
                localStorage.setItem('accountCollapsed', JSON.stringify([...this.collapsed]));
            });
        },

        collapsed: new Set(),

        toggle(account) {
            if (this.collapsed.has(account)) {
                this.collapsed.delete(account);
            } else {
                this.collapsed.add(account);
            }
        },

        isExpanded(account) {
            return !this.collapsed.has(account);
        },

        isVisible(account) {
            const parts = account.split(':');
            for (let i = 1; i < parts.length; i++) {
                const prefix = parts.slice(0, i).join(':');
                if (this.collapsed.has(prefix)) {
                    return false;
                }
            }
            return true;
        }
    })
});
