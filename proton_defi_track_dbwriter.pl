# install dependencies:
#  sudo apt install cpanminus libjson-xs-perl libjson-perl libmysqlclient-dev libdbi-perl
#  sudo cpanm Net::WebSocket::Server
#  sudo cpanm DBD::MariaDB

use strict;
use warnings;
use JSON;
use Getopt::Long;
use DBI;
use Time::HiRes qw (time);
use Time::Local 'timegm_nocheck';

use Net::WebSocket::Server;
use Protocol::WebSocket::Frame;

$Protocol::WebSocket::Frame::MAX_PAYLOAD_SIZE = 100*1024*1024;
$Protocol::WebSocket::Frame::MAX_FRAGMENTS_AMOUNT = 102400;

$| = 1;

my $network;

my $port = 8800;

my $dsn = 'DBI:MariaDB:database=proton_defi_track;host=localhost';
my $db_user = 'proton_defi_track';
my $db_password = 'keiH8eej';
my $commit_every = 10;
my $endblock = 2**32 - 1;
my $loan_contract = 'lending.loan';
my $shares_contract = 'shares.loan';

my $ok = GetOptions
    ('network=s' => \$network,
     'port=i'    => \$port,
     'ack=i'     => \$commit_every,
     'endblock=i'  => \$endblock,
     'dsn=s'     => \$dsn,
     'dbuser=s'  => \$db_user,
     'dbpw=s'    => \$db_password,
     'loan=s'    => \$loan_contract,
     'shares=s'  => \$shares_contract,
    );


if( not $network or not $ok or scalar(@ARGV) > 0 )
{
    print STDERR "Usage: $0 --network=X [options...]\n",
        "Options:\n",
        "  --network=X        network name\n",
        "  --port=N           \[$port\] TCP port to listen to websocket connection\n",
        "  --ack=N            \[$commit_every\] Send acknowledgements every N blocks\n",
        "  --endblock=N       \[$endblock\] Stop before given block\n",
        "  --dsn=DSN          \[$dsn\]\n",
        "  --dbuser=USER      \[$db_user\]\n",
        "  --dbpw=PASSWORD    \[$db_password\]\n";
    exit 1;
}


my $dbh = DBI->connect($dsn, $db_user, $db_password,
                       {'RaiseError' => 1, AutoCommit => 0,
                        mariadb_server_prepare => 1});
die($DBI::errstr) unless $dbh;


my $sth_add_lend = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_LEND ' .
     '(seq, block_num, block_time, trx_id, lender, tkcontract, currency, amount, shares_currency, shares_amount) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?)');

my $sth_add_borrow = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_BORROW ' .
     '(seq, block_num, block_time, trx_id, borrower, tkcontract, currency, amount, user_borrow_rate, utilization) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?)');

my $sth_add_repay = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_REPAY ' .
     '(seq, block_num, block_time, trx_id, borrower, payer, tkcontract, currency, amount, user_borrow_rate, utilization) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?,?)');


my $sth_add_liquidate = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_LIQUIDATE ' .
     '(seq, block_num, block_time, trx_id, borrower,  liquidator, seized_tkcontract, seized_currency, seized_amount, ' .
     'repaid_tkcontract, repaid_currency, repaid_amount, value_repaid, value_seized) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)');


my $sth_add_claim = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_CLAIM ' .
     '(seq, block_num, block_time, trx_id, claimer, market, tkcontract, currency, amount) ' .
     'VALUES(?,?,?,?,?,?,?,?,?)');

my $sth_add_redeem = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_REDEEM ' .
     '(seq, block_num, block_time, trx_id, redeemer, redeem_tkcontract, redeem_currency, redeem_amount, ' .
     'issued_tkcontract, issued_currency, issued_amount, ' .
     'payout_tkcontract, payout_currency, payout_amount) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)');

my $sth_add_tbl_borrows = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_TBL_BORROWS ' .
     '(block_num, block_time, account, tkcontract, currency, variable_principal, variable_interest_index, ' .
     'stable_principal, last_stable_update, stable_rate) ' .
     'VALUES(?,?,?,?,?,?,?,?,?,?)');

my $sth_add_tbl_markets = $dbh->prepare
    ('INSERT INTO ' . $network . '_LOAN_TBL_MARKETS ' .
     '(block_num, block_time, tkcontract, currency, borrow_index, variable_accrual_time, ' .
     'total_variable_borrows, total_reserves) ' .
     'VALUES(?,?,?,?,?,?,?,?)');

my $sth_upd_sync = $dbh->prepare
    ('INSERT INTO SYNC (network, block_num, block_time) VALUES(?,?,?) ' .
     'ON DUPLICATE KEY UPDATE block_num=?, block_time=?');

my $committed_block = 0;
my $stored_block = 0;
my $uncommitted_block = 0;
{
    my $sth = $dbh->prepare
        ('SELECT block_num FROM SYNC WHERE network=?');
    $sth->execute($network);
    my $r = $sth->fetchall_arrayref();
    if( scalar(@{$r}) > 0 )
    {
        $stored_block = $r->[0][0];
        printf STDERR ("Starting from stored_block=%d\n", $stored_block);
    }
}




my $json = JSON->new;

my $blocks_counter = 0;
my $actions_counter = 0;
my $counter_start = time();

Net::WebSocket::Server->new(
    listen => $port,
    on_connect => sub {
        my ($serv, $conn) = @_;
        $conn->on(
            'binary' => sub {
                my ($conn, $msg) = @_;
                my ($msgtype, $opts, $js) = unpack('VVa*', $msg);
                my $data = eval {$json->decode($js)};
                if( $@ )
                {
                    print STDERR $@, "\n\n";
                    print STDERR $js, "\n";
                    exit;
                }

                my $ack = process_data($msgtype, $data);
                if( $ack >= 0 )
                {
                    $conn->send_binary(sprintf("%d", $ack));
                    print STDERR "ack $ack\n";
                }

                if( $ack >= $endblock )
                {
                    print STDERR "Reached end block\n";
                    exit(0);
                }
            },
            'disconnect' => sub {
                my ($conn, $code) = @_;
                print STDERR "Disconnected: $code\n";
                $dbh->rollback();
                $committed_block = 0;
                $uncommitted_block = 0;
            },
            );
    },
    )->start;


sub process_data
{
    my $msgtype = shift;
    my $data = shift;

    if( $msgtype == 1001 ) # CHRONICLE_MSGTYPE_FORK
    {
        my $block_num = $data->{'block_num'};
        print STDERR "fork at $block_num\n";
        $uncommitted_block = 0;
        return $block_num-1;
    }
    elsif( $msgtype == 1003 ) # CHRONICLE_MSGTYPE_TX_TRACE
    {
        if( $data->{'block_num'} > $stored_block )
        {
            my $trace = $data->{'trace'};
            if( $trace->{'status'} eq 'executed' )
            {
                my $block_time = $data->{'block_timestamp'};
                $block_time =~ s/T/ /;

                my $tx = { block_num => $data->{'block_num'},
                           block_time => $block_time,
                           trx_id => $trace->{'id'} };

                foreach my $atrace (@{$trace->{'action_traces'}})
                {
                    process_atrace($atrace, $tx);
                }

                if( defined($tx->{'redeem'}) )
                {
                    my $r = $tx->{'redeem'};
                    $sth_add_redeem->execute
                        ($r->{'seq'}, $data->{'block_num'}, $block_time, $trace->{'id'},
                         $r->{'redeemer'}, $r->{'redeem_tkcontract'}, $r->{'redeem_currency'}, $r->{'redeem_amount'},
                         $r->{'issued_tkcontract'}, $r->{'issued_currency'}, $r->{'issued_amount'},
                         $r->{'payout_tkcontract'}, $r->{'payout_currency'}, $r->{'payout_amount'});
                    print STDERR "!";
                }
                elsif( defined($tx->{'lend'}) )
                {
                    my $r = $tx->{'lend'};
                    $sth_add_lend->execute
                        ($r->{'seq'}, $data->{'block_num'}, $block_time, $trace->{'id'},
                         $r->{'lender'}, $r->{'tkcontract'}, $r->{'currency'}, $r->{'amount'},
                         $r->{'shares_currency'}, $r->{'shares_amount'});
                    print STDERR "<";
                }
            }
        }
    }
    elsif( $msgtype == 1007 ) # CHRONICLE_MSGTYPE_TBL_ROW
    {
        if( $data->{'block_num'} > $stored_block )
        {
            my $kvo = $data->{'kvo'};
            my $contract = $kvo->{'code'};

            return(-1) unless $contract eq $loan_contract;
            return(-1) unless ref($kvo->{'value'}) eq 'HASH';

            my $block_num = $data->{'block_num'};
            my $block_time = $data->{'block_timestamp'};
            $block_time =~ s/T/ /;

            my $scope = $kvo->{'scope'};
            my $tbl = $kvo->{'table'};

            if( $tbl eq 'borrows' and $scope eq $loan_contract )
            {
                my $val = $kvo->{'value'};
                my $account = $val->{'account'};
                foreach my $entry (@{$val->{'tokens'}})
                {
                    my $value = $entry->{'value'};
                    my $last_stable_update = $value->{'last_stable_update'};
                    $last_stable_update =~ s/T/ /;

                    # convert 8,LBTC to LBTC
                    my ($precision, $currency) = split(/,/, $entry->{'key'}{'sym'});

                    if( $data->{'added'} eq 'true' )
                    {
                        $sth_add_tbl_borrows->execute
                            ($block_num, $block_time, $account,
                             $entry->{'key'}{'contract'}, $currency,
                             $value->{'variable_principal'} / 10**$precision, $value->{'variable_interest_index'},
                             $value->{'stable_principal'}, $last_stable_update, $value->{'stable_rate'});
                    }
                    else {
                        $sth_add_tbl_borrows->execute
                            ($block_num, $block_time, $account,
                             $entry->{'key'}{'contract'}, $currency,
                             0, 0, 0, $last_stable_update, 0);
                    }
                }
            }
            elsif( $tbl eq 'markets' and $scope eq $loan_contract and $data->{'added'} eq 'true' )
            {
                my $val = $kvo->{'value'};

                my $variable_accrual_time = $val->{'variable_accrual_time'};
                $variable_accrual_time =~ s/T/ /;

                # convert 8,LBTC to LBTC
                my $share_currency = $val->{'share_symbol'}{'sym'};
                $share_currency =~ s/^\d+,//;

                my $currency;
                my $total_variable_borrows;
                my $asset = $val->{'total_variable_borrows'}{'quantity'};
                ($total_variable_borrows, $currency) = split(/\s+/, $asset);

                my $total_reserves;
                $asset = $val->{'total_reserves'}{'quantity'};
                ($total_reserves, $currency) = split(/\s+/, $asset);

                $sth_add_tbl_markets->execute
                    ($block_num, $block_time, $val->{'share_symbol'}{'contract'}, $share_currency,
                     $val->{'borrow_index'}, $variable_accrual_time, $total_variable_borrows, $total_reserves);
            }
        }
    }
    elsif( $msgtype == 1010 ) # CHRONICLE_MSGTYPE_BLOCK_COMPLETED
    {
        $blocks_counter++;
        $uncommitted_block = $data->{'block_num'};
        if( $uncommitted_block - $committed_block >= $commit_every or
            $uncommitted_block >= $endblock )
        {
            $committed_block = $uncommitted_block;

            my $gap = 0;
            {
                my ($year, $mon, $mday, $hour, $min, $sec, $msec) =
                    split(/[-:.T]/, $data->{'block_timestamp'});
                my $epoch = timegm_nocheck($sec, $min, $hour, $mday, $mon-1, $year);
                $gap = (time() - $epoch)/3600.0;
            }

            my $period = time() - $counter_start;
            printf STDERR ("blocks/s: %5.2f, actions/block: %5.2f, actions/s: %5.2f, gap: %6.2fh, ",
                           $blocks_counter/$period, $actions_counter/$blocks_counter, $actions_counter/$period,
                           $gap);
            $counter_start = time();
            $blocks_counter = 0;
            $actions_counter = 0;

            if( $uncommitted_block > $stored_block )
            {
                my $block_time = $data->{'block_timestamp'};
                $block_time =~ s/T/ /;
                $sth_upd_sync->execute($network, $uncommitted_block, $block_time, $uncommitted_block, $block_time);
                $dbh->commit();
                $stored_block = $uncommitted_block;
            }
            return $committed_block;
        }
    }

    return -1;
}


sub process_atrace
{
    my $atrace = shift;
    my $tx = shift;

    my $act = $atrace->{'act'};
    my $contract = $act->{'account'};
    my $receipt = $atrace->{'receipt'};

    if( $receipt->{'receiver'} ne $contract )
    {
        return;
    }

    my $aname = $act->{'name'};
    my $data = $act->{'data'};

    if( ref($data) ne 'HASH' )
    {
        return;
    }

    my $seq = $receipt->{'global_sequence'};
    my $block_num = $tx->{'block_num'};
    my $block_time = $tx->{'block_time'};
    my $trx_id = $tx->{'trx_id'};

    if( ($aname eq 'transfer') and defined($data->{'quantity'}) and defined($data->{'to'}) and defined($data->{'from'}) )
    {
        my $to = $data->{'to'};
        my $from = $data->{'from'};
        if( $to eq $loan_contract or $from eq $loan_contract )
        {
            my ($amount, $currency) = split(/\s+/, $data->{'quantity'});
            if( not defined($amount) or not defined($currency) or
                $amount !~ /^[0-9.]+$/ or $currency !~ /^[A-Z]{1,7}$/ )
            {
                return;
            }

            if( $to eq $loan_contract )
            {
                if( $data->{'memo'} eq 'mint' )
                {
                    $tx->{'lend'} = {};
                    my $r = $tx->{'lend'};
                    $r->{'seq'} = $seq;
                    $r->{'lender'} = $from;
                    $r->{'tkcontract'} = $contract;
                    $r->{'currency'} = $currency;
                    $r->{'amount'} = $amount;
                }
            }
            elsif( $data->{'memo'} =~ /^claim\s+([A-Z]{1,7})/ )
            {
                $sth_add_claim->execute($seq, $block_num, $block_time, $trx_id, $to, $1, $contract, $currency, $amount);
                print STDERR ">";
            }
            elsif( $data->{'memo'} eq 'redeem' )
            {
                if( defined($tx->{'redeem'}) )
                {
                    my $r = $tx->{'redeem'};
                    $r->{'payout_tkcontract'} = $contract;
                    $r->{'payout_currency'} = $currency;
                    $r->{'payout_amount'} = $amount;
                }
                else
                {
                    printf STDERR ("outgoing transfer without proper redeem action: block=%d, txid=%s\n",
                                   $block_num, $trx_id);
                    exit(1);
                }
            }

            $actions_counter++;
        }
    }
    elsif( $contract eq $loan_contract )
    {
        if( $aname eq 'log.borrow' )
        {
            my $asset = $data->{'underlying'}{'quantity'};
            my ($amount, $currency) = split(/\s+/, $asset);
            $sth_add_borrow->execute($seq, $block_num, $block_time, $trx_id,
                                     $data->{'borrower'}, $data->{'underlying'}{'contract'}, $currency, $amount,
                                     $data->{'user_borrow_rate'}, $data->{'utilization'});
            $actions_counter++;
            print STDERR ".";
        }
        elsif( $aname eq 'log.repay' )
        {
            my $asset = $data->{'underlying_repaid'}{'quantity'};
            my ($amount, $currency) = split(/\s+/, $asset);
            $sth_add_repay->execute($seq, $block_num, $block_time, $trx_id,
                                    $data->{'borrower'}, $data->{'payer'},
                                    $data->{'underlying_repaid'}{'contract'}, $currency, $amount,
                                    $data->{'user_borrow_rate'}, $data->{'utilization'});
            $actions_counter++;
            print STDERR "+";
        }
        elsif( $aname eq 'log.seize' )
        {
            my $asset_seized = $data->{'tokens_seized'}{'quantity'};
            my ($amount_seized, $currency_seized) = split(/\s+/, $asset_seized);
            my $asset_repaid = $data->{'underlying_repaid'}{'quantity'};
            my ($amount_repaid, $currency_repaid) = split(/\s+/, $asset_repaid);
            $sth_add_liquidate->execute($seq, $block_num, $block_time, $trx_id,
                                        $data->{'borrower'}, $data->{'liquidator'},
                                        $data->{'tokens_seized'}{'contract'}, $currency_seized, $amount_seized,
                                        $data->{'underlying_repaid'}{'contract'}, $currency_repaid, $amount_repaid,
                                        $data->{'value_repaid'}, $data->{'value_seized'});
            $actions_counter++;
            print STDERR "-";
        }
        elsif( $aname eq 'redeem' )
        {
            $tx->{'redeem'} = {};
            my $r = $tx->{'redeem'};
            $r->{'seq'} = $seq;
            $r->{'redeemer'} = $data->{'redeemer'};
            $r->{'redeem_tkcontract'} = $data->{'token'}{'contract'};
            my $asset = $data->{'token'}{'quantity'};
            my ($amount, $currency) = split(/\s+/, $asset);
            $r->{'redeem_currency'} = $currency;
            $r->{'redeem_amount'} = $amount;
            $actions_counter++;
        }
    }
    elsif( ($aname eq 'issue') and defined($data->{'quantity'}) and defined($data->{'to'}) )
    {
        my $to = $data->{'to'};
        if( $to eq $loan_contract )
        {
            my ($amount, $currency) = split(/\s+/, $data->{'quantity'});
            if( not defined($amount) or not defined($currency) or
                $amount !~ /^[0-9.]+$/ or $currency !~ /^[A-Z]{1,7}$/ )
            {
                return;
            }

            if( defined($tx->{'redeem'}) )
            {
                my $r = $tx->{'redeem'};
                $r->{'issued_tkcontract'} = $contract;
                $r->{'issued_currency'} = $currency;
                $r->{'issued_amount'} = $amount;
            }
            elsif( defined($tx->{'lend'}) and $contract eq $shares_contract )
            {
                my $r = $tx->{'lend'};
                $r->{'shares_currency'} = $currency;
                $r->{'shares_amount'} = $amount;
            }
        }
    }
}
