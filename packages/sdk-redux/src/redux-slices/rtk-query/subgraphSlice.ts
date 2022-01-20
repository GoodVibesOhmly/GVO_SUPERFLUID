import type {ModuleName} from '@reduxjs/toolkit/dist/query/apiTypes';
import {BaseQueryFn, CreateApi} from '@reduxjs/toolkit/query';
import {
    Account,
    AccountQueryHandler,
    AccountTokenSnapshot,
    AccountTokenSnapshotQueryHandler,
    ILightEntity,
    Index,
    IndexQueryHandler,
    IndexSubscription,
    IndexSubscriptionQueryHandler,
    IndexUpdatedEvent,
    IndexUpdatedEventQueryHandler,
    PagedResult,
    RelevantAddressProviderFromFilter,
    RelevantAddressProviderFromResult,
    Stream,
    StreamPeriod,
    StreamPeriodQueryHandler,
    StreamQueryHandler,
    SubgraphGetQueryHandler,
    SubgraphListQuery,
    SubgraphListQueryHandler,
    SubscriptionUnitsUpdatedEvent,
    SubscriptionUnitsUpdatedEventQueryHandler,
    Token,
    TokenQueryHandler,
    TokenStatistic,
    TokenStatisticQueryHandler,
} from '@superfluid-finance/sdk-core';

import {getFramework} from '../../sdkReduxConfig';
import {typeGuard} from '../../utils';
import {BaseGetQuery, BaseQuery, BaseQuery2} from '../argTypes';

import {CacheTagTypes} from './cacheTags/CacheTagTypes';
import {
    GetAccount,
    GetAccountTokenSnapshot,
    GetIndex2,
    GetIndexSubscription,
    GetIndexUpdatedEvent,
    GetStream2,
    GetStreamPeriod,
    GetSubscriptionUnitsUpdatedEvent,
    GetToken,
    GetTokenStatistic,
    ListAccounts,
    ListAccountTokenSnapshots,
    ListIndexes2,
    ListIndexSubscriptions2,
    ListIndexUpdatedEvents,
    ListStreamPeriods,
    ListStreams2,
    ListSubscriptionUnitsUpdatedEvents,
    ListTokens,
    ListTokenStatistics,
} from './entities/entityQueries';
import {provideTagsFromRelevantAddresses} from './entities/provideTagsFromRelevantAddresses';
import {getSerializeQueryArgs} from './getSerializeQueryArgs';
import {ValidationError} from './returnTypes';

export const subgraphSliceBaseQuery = (): BaseQueryFn<
    BaseQuery<unknown>,
    Record<string, unknown>,
    ValidationError,
    unknown,
    never
> =>
    function () {
        throw new Error('All queries & mutations must use the `queryFn` definition syntax.');
    };

export const createSubgraphSlice = <T extends ModuleName>(createRtkQueryApi: CreateApi<T>) => {
    return createRtkQueryApi({
        reducerPath: 'sfSubgraph',
        baseQuery: subgraphSliceBaseQuery(),
        tagTypes: typeGuard<CacheTagTypes[]>(['Event', 'Index', 'Stream', 'Token']),
        endpoints: (builder) => {
            function get<TReturn extends ILightEntity, TQuery extends BaseGetQuery<TReturn>>(
                queryHandler: SubgraphGetQueryHandler<TReturn> & RelevantAddressProviderFromResult<TReturn>,
                tag: CacheTagTypes
            ) {
                return builder.query<TReturn | null, TQuery>({
                    queryFn: async (arg) => {
                        const framework = await getFramework(arg.chainId);
                        const {chainId, ...query} = arg;
                        const result = await queryHandler.get(framework.query.subgraphClient, query);
                        return {
                            data: result,
                        };
                    },
                    providesTags: (result, _error, arg) => {
                        if (!result) {
                            return [];
                        }

                        const relevantAddresses = queryHandler.getRelevantAddressesFromResult(result);
                        return provideTagsFromRelevantAddresses(arg.chainId, relevantAddresses, tag);
                    },
                });
            }

            function list<
                TReturn extends ILightEntity,
                TQuery extends BaseQuery2 & SubgraphListQuery<TFilter, TOrderBy>,
                TFilter extends {[key: string]: unknown} = NonNullable<TQuery['filter']>,
                TOrderBy extends string = NonNullable<TQuery['order']>['orderBy']
            >(
                queryHandler: SubgraphListQueryHandler<TReturn, TQuery, TFilter> &
                    RelevantAddressProviderFromFilter<TFilter>,
                tag: CacheTagTypes
            ) {
                return builder.query<PagedResult<TReturn>, TQuery>({
                    queryFn: async (arg) => {
                        const framework = await getFramework(arg.chainId);
                        const {chainId, ...query} = arg;
                        const result = await queryHandler.list(framework.query.subgraphClient, query);
                        return {
                            data: result,
                        };
                    },
                    providesTags: (_result, _error, arg) => {
                        const relevantAddresses = queryHandler.getRelevantAddressesFromFilter(arg.filter);
                        return provideTagsFromRelevantAddresses(arg.chainId, relevantAddresses, tag);
                    },
                });
            }

            return {
                account: get<Account, GetAccount>(new AccountQueryHandler(), 'Event'),
                accounts: list<Account, ListAccounts>(new AccountQueryHandler(), 'Event'),
                accountTokenSnapshot: get<AccountTokenSnapshot, GetAccountTokenSnapshot>(
                    new AccountTokenSnapshotQueryHandler(),
                    'Event'
                ),
                accountTokenSnapshots: list<AccountTokenSnapshot, ListAccountTokenSnapshots>(
                    new AccountTokenSnapshotQueryHandler(),
                    'Token'
                ),
                index: get<Index, GetIndex2>(new IndexQueryHandler(), 'Index'),
                indexes: list<Index, ListIndexes2>(new IndexQueryHandler(), 'Index'),
                indexSubscription: get<IndexSubscription, GetIndexSubscription>(
                    new IndexSubscriptionQueryHandler(),
                    'Index'
                ),
                indexSubscriptions: list<IndexSubscription, ListIndexSubscriptions2>(
                    new IndexSubscriptionQueryHandler(),
                    'Index'
                ),
                stream: get<Stream, GetStream2>(new StreamQueryHandler(), 'Stream'),
                streams: list<Stream, ListStreams2>(new StreamQueryHandler(), 'Stream'),
                streamPeriod: get<StreamPeriod, GetStreamPeriod>(new StreamPeriodQueryHandler(), 'Stream'),
                streamPeriods: list<StreamPeriod, ListStreamPeriods>(new StreamPeriodQueryHandler(), 'Stream'),
                token: get<Token, GetToken>(new TokenQueryHandler(), 'Token'),
                tokens: list<Token, ListTokens>(new TokenQueryHandler(), 'Token'),
                tokenStatistic: get<TokenStatistic, GetTokenStatistic>(new TokenStatisticQueryHandler(), 'Token'),
                tokenStatistics: list<TokenStatistic, ListTokenStatistics>(new TokenStatisticQueryHandler(), 'Token'),
                indexUpdatedEvent: get<IndexUpdatedEvent, GetIndexUpdatedEvent>(
                    new IndexUpdatedEventQueryHandler(),
                    'Event'
                ),
                indexUpdatedEvents: list<IndexUpdatedEvent, ListIndexUpdatedEvents>(
                    new IndexUpdatedEventQueryHandler(),
                    'Event'
                ),
                subscriptionUnitsUpdatedEvent: get<SubscriptionUnitsUpdatedEvent, GetSubscriptionUnitsUpdatedEvent>(
                    new SubscriptionUnitsUpdatedEventQueryHandler(),
                    'Event'
                ),
                subscriptionUnitsUpdatedEvents: list<SubscriptionUnitsUpdatedEvent, ListSubscriptionUnitsUpdatedEvents>(
                    new SubscriptionUnitsUpdatedEventQueryHandler(),
                    'Event'
                ),
            };
        },
        serializeQueryArgs: getSerializeQueryArgs(),
    });
};

// NOTE: This might not include all the type info.
export type SfSubgraphSliceInferredType = ReturnType<typeof createSubgraphSlice>;
