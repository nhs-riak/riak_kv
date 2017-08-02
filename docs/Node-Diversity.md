# Node Diversity

## Background
At NHS Digital, we use Riak for a variety of applications that store patient information and data, which are vital to healthcare within the UK NHS system. These include patient demographics data, prescriptions, clinical summary records, and much more.

Once we receive and acknowledge a reliable message from a partner system, we guarantee that we will not lose this message, and that it will be processed.

As a distributed database Riak helps us keep this guarantee, and helps us to ensure once we have processed such a message, we don't lose the patient data or the changes made to it.

Obviously, one of the useful features of a distributed database is that this data is written to more than one node. To achieve this, we have historically used the primary write option in Riak, setting pw=2. Assuming that a ring's partitions are distributed perfectly, assigning pw=2 ensures that our writes will always go to physically diverse nodes.

If one node fails, then the fallback node may or may not be a physically diverse node, but since we wait until pw=2 is satisfied, we know it will write to two diverse nodes.

## The Problem
The problem starts when a second node fails. This means that pw=2 cannot be satisfied, as the preflist for some writes now contains a single primary node and two fallback nodes. At this point if pw=2 has been satisfied the cluster begins to reject writes where the preflist contains only one primary node.

This was seen in production when two nodes failed in quick succession due to a bad batch of write cache batteries, and where the standby cluster started silently rejecting writes from some of the replication traffic, which was only noticed when our reconciliation process kicked in and flagged up the discrepancies between the clusters.

Since our clusters have 7-9 nodes, this seems unreasonable, as there are plenty of nodes to statisfy w=3, even if these need to be writes to fallback nodes, rather than primary nodes. We only want to ensure that writes occur on different physical nodes.

## The Solution
The problem stems from attempting to use an option to achieve something the option was never originally intended to achieve. Therefore the solution was to build a new option which is meant to solve the exact issue, i.e. that of node diversity.

### What's in an option name?
So of course the big question is what to call the option? _'pd'_ (physical diversity) was considered, but the option only provides node diversity and cannot guarantee physical diversity (see Limitations). _'nd'_ was considered but both 'n' and 'd' are already specific terms within Riak and may lead to confusion.

Terms such as _'node_diversity'_ sound like a boolean option, rather than expecting an integer number.

Hence we have decided to call this option _'node_confirms'_,as this is the number of different nodes we require to confirm their write has been successful. We chose to break from the 'traditional' two letter options such as pw and dw as they are vnode based options, whereas this is a node based option, and it is also more descriptive.

## Implementation
The implementation is very straight forward. We wait for sufficient _'dw'_ results to come in from different nodes that satisfy the _'node_confirms'_. This is done by adding the node name for each write to the tuple passed into the counting mechanism used to count _'pw'_ results, and extending that mechanism to count the different nodes that have responded.

## Testing
Testing is done by adding unit tests for the count mechanisms, and by creating a riak_test that does the following:
* Start a 5 node cluster
* Get a preflist for a key
* Stop 2 primary nodes for that key
* Wait for a new preflist confirming there are 2 fallbacks
* Check a pw=2 write fails
* Check a node_confirms=2 write succeeds
* Check a node_confirms=4 write is rejected as a bad value (n_val=3!)
* Stop another node in the preflist (now only 2 nodes remain up)
* Wait for a new preflist
* Check a node_confirms=3 write fails

## Limitations
While this goes a way to providing physical diversity, there are limitations to this solution, and it is only a start. For instance, there is no concept of rack awareness and rack diversity. If the nodes are based in the cloud, there is no easy way to determine whether the backend database for a node is stored on the same physical storage device as that for another node, nor is there any awareness of availability zones.

Solving these issues would require more engineering effort, and for the purposes of NHS Riak, is not currently required.
