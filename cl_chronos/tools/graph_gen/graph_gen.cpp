/** $lic$
 * Copyright (C) 2014-2019 by Massachusetts Institute of Technology
 *
 * This file is part of the Chronos FPGA Acceleration Framework.
 *
 * Chronos is free software; you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, version 2.
 *
 * If you use this framework in your research, we request that you reference
 * the Chronos paper ("Chronos: Efficient Speculative Parallelism for
 * Accelerators", Abeydeera and Sanchez, ASPLOS-25, March 2020), and that
 * you send us a citation of your work.
 *
 * Chronos is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 */

#define MAGIC_OP 0xdead
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdlib.h>
#include <tuple>
#include <utility>
#include <vector>
#include <set>
#include <map>
#include <unordered_set>
#include <queue>
#include <random>
#include <numeric>

struct Node {
   uint32_t vid;
   uint32_t dist;
   uint32_t bucket;
};

struct NodeSort {
   uint32_t vid;
   uint32_t degree;
};
struct degree_sort {
   bool operator() (const NodeSort &a, const NodeSort &b) const {
      int a_deg = a.degree;
      int b_deg = b.degree;
      bool ret = (a_deg > b_deg) ||
                  ( (a_deg == b_deg) && (a.vid < b.vid)) ;
      //printf(" (%d %d), (%d,%d) %d\n", a.degree, a.vid, b.degree, b.vid, ret);
      return ret;
   }
};

#define APP_SSSP 0
#define APP_COLOR 1
#define APP_MAXFLOW 2
const double EarthRadius_cm = 637100000.0;

struct Vertex;

struct Adj {
   uint32_t n;
   uint32_t d_cm; // edge weight
   uint32_t index; // index of the reverse edge
};

struct Vertex {
   double lat, lon;  // in RADIANS
   std::vector<Adj> adj;
};

Vertex* graph;
uint32_t numV;
uint32_t numE;
uint32_t startNode;
uint32_t endNode;

int app = APP_SSSP;

uint32_t* csr_offset;
Adj* csr_neighbors;
uint32_t* csr_dist;

void addEdge(uint32_t from, uint32_t to, uint32_t cap) {
    bool combine_edges = true;
    if (combine_edges) {
      for (Adj& a : graph[from].adj) {
         if (a.n == to) {
            a.d_cm = cap;
            graph[to].adj[a.index].d_cm = cap;
            return;
         }
      }

    }

    // Push edge to _graph[node]
    Adj adj_from = {to, cap, (uint32_t) graph[to].adj.size()};
    graph[from].adj.push_back(adj_from);

    // Insert the reverse edge (residual graph)
    Adj adj_to = {from, 0, (uint32_t) graph[from].adj.size()-1};
    graph[to].adj.push_back(adj_to);
    //printf("Edge %d %d %d\n", from, to, cap);
}

uint64_t dist(const Vertex* src, const Vertex* dst) {
   // Use the haversine formula to compute the great-angle radians
   double latS = std::sin(src->lat - dst->lat);
   double lonS = std::sin(src->lon - dst->lon);
   double a = latS*latS + lonS*lonS*std::cos(src->lat)*std::cos(dst->lat);
   double c = 2*std::atan2(std::sqrt(a), std::sqrt(1-a));

   uint64_t d_cm = c*EarthRadius_cm;
   return d_cm;
}

void LoadGraphGR(const char* file) {
   // DIMACS
   std::ifstream f;
   std::string s;
   f.open(file, std::ios::binary);
   if (!f.is_open()) {
      printf("ERROR: Could not open input file\n");
      exit(1);
   }
   int n =0;
   while(!f.eof()) {
      std::getline(f, s);
      if (s.c_str()[0]=='c') continue;
      if (s.c_str()[0]=='n') {
         char st;
         uint32_t r;
         sscanf(s.c_str(), "%*s %d %c\n", &r, &st);
         if (st=='s') startNode = r-1;
         if (st=='t') endNode = r-1;
      }
      if (s.c_str()[0]=='p') {
         sscanf(s.c_str(), "%*s %*s %d %d\n", &numV, &numE);
         graph = new Vertex[numV];
      }
      if (s.c_str()[0]=='a') {
         uint32_t src, dest, w;
         sscanf(s.c_str(), "%*s %d %d %d\n", &src, &dest, &w);
         if (app == APP_MAXFLOW) {
            addEdge(src-1, dest-1, w);
         } else {
            Adj a = {dest-1,w};
            graph[src-1].adj.push_back(a);
         }
      }

      n++;
   }
   printf("n %d %d %d\n",n, numV, numE);

}
void LoadGraphEdges(const char* file) {
   std::ifstream f;
   std::string s;
   f.open(file, std::ios::binary);
   if (!f.is_open()) {
      printf("ERROR: Could not open input file\n");
      exit(1);
   }
   int n =0;
   numV = 1157828; // hack: com-youtube
   graph = new Vertex[numV];
   while(!f.eof()) {
      std::getline(f, s);
      if (s.c_str()[0]=='E') continue;
      else {
         uint32_t src, dest;
         sscanf(s.c_str(), "%d %d\n", &src, &dest);
         //printf("%d %d\n", src, dest);
         if (src > numV || dest > numV) continue;
         Adj a = {dest-1,0};
         graph[src-1].adj.push_back(a);
      }

      n++;
   }
   printf("%d %d\n", numV, numE);

}
void LoadGraph(const char* file) {
   const uint32_t MAGIC_NUMBER = 0x150842A7 + 0; // increment every time you change the file format
   std::ifstream f;
   f.open(file, std::ios::binary);
   if (!f.is_open()) {
      printf("ERROR: Could not open input file\n");
      exit(1);
   }

   auto readU = [&]() -> uint32_t {
      union U {
         uint32_t val;
         char bytes[sizeof(uint32_t)];
      };
      U u;
      f.read(u.bytes, sizeof(uint32_t));
      // assert(!f.fail());
      return u.val;
   };

   auto readD = [&]() -> double {
      union U {
         double val;
         char bytes[sizeof(double)];
      };
      U u;
      f.read(u.bytes, sizeof(double));
      // assert(!f.fail());
      return u.val;
   };

   uint32_t magic = readU();
   if (magic != MAGIC_NUMBER) {
      printf("ERROR: Wrong input file format (magic number %d, expected %d)\n",
            magic, MAGIC_NUMBER);
      exit(1);
   }

   numV = readU();
   printf("Reading %d nodes...\n", numV);

   graph = new Vertex[numV];
   uint32_t i = 0;
   while (i < numV) {
      graph[i].lat = readD();
      graph[i].lon = readD();
      uint32_t n = readU();
      graph[i].adj.resize(n);
      for (uint32_t j = 0; j < n; j++) graph[i].adj[j].n = readU();
      for (uint32_t j = 0; j < n; j++) graph[i].adj[j].d_cm = readD()*EarthRadius_cm;
      i++;

   }

   f.get();
   // assert(f.eof());

#if 0
   // Print graph
   for (uint32_t i = 0; i < numV; i++) {
      printf("%6d: %7f %7f", i, graph[i].lat, graph[i].lon);
      for (auto a: graph[i].adj) printf(" %5ld %7f", a.n-graph, a.d);
      printf("\n");
   }
#endif

}

void GenerateGridGraph(uint32_t n) {
   numV = n*n;
   numE = 2 * n * (n-1) ;
   graph = new Vertex[numV];
   bool debug = false;
   srand(0);
   for (uint32_t i=0;i<n;i++){
      for (uint32_t j=0;j<n;j++){
         uint32_t vid = i*n+j;
         if (i < n-1) {
            Adj e;
            e.n = (vid+n);
            e.d_cm = rand() % 10;
            graph[vid].adj.push_back(e);
            if(debug) printf("%d->%d %d\n", vid, e.n, e.d_cm);
         }
         if (j < n-1) {
            Adj e;
            e.n = (vid+1);
            e.d_cm = rand() % 10;
            graph[vid].adj.push_back(e);
            if(debug) printf("%d->%d %d\n", vid, e.n, e.d_cm);
         }
      }
   }

   // Add extra edges to get a high-fanout node
    /*
   for (int j=30;j<100;j++) {
      Adj e;
      e.n=j;
      e.d_cm = 0;
      graph[15].adj.push_back(e);
   } */
}

// code copied from suvinay's maxflow graph generator
void choose_k(int to, std::vector<int>* vec, int k, int seed) {
    std::vector<int> numbers;
    numbers.resize(to);
    std::iota(numbers.begin(), numbers.end(), 0);   // Populate numbers from 0 to (to-1)
    //std::shuffle(numbers.begin(), numbers.end(), std::mt19937{std::random_device{}()}); // Shuffle them
    std::shuffle(numbers.begin(), numbers.end(), std::default_random_engine(seed));
    std::copy_n(numbers.begin(), k, vec->begin()); // Copy the first k in the shuffled array to vec
    return;
}

void GenerateGridGraphMaxflow(uint32_t r, uint32_t c, uint32_t num_connections) {
   srand(42);
   numV = r*c + 2;
   const int MAX_CAPACITY = 10;
   const int MIN_CAPACITY = 1;
   graph = new Vertex[numV];
   uint32_t i, j;
   for (i = 0; i < r - 1; ++i) {
      for (j = 0; j < c; ++j) {
         std::vector<int> connections;
         connections.resize(num_connections);
         choose_k(c, &connections, num_connections, rand());
         for (auto &x : connections) {
            uint32_t capacity = static_cast<uint32_t>(
                  rand() % (MAX_CAPACITY - MIN_CAPACITY) + MIN_CAPACITY);
            addEdge(i*c+j, (i+1)*c+x, capacity);
            //printf("a %d %d %d\n", i * c + j, (i + 1) * c + x, capacity);
         }
      }
   }
   for (i = 0; i < c; ++i) {
      uint32_t capacity = static_cast<uint32_t>
         (rand() % (MAX_CAPACITY - MIN_CAPACITY) + MIN_CAPACITY);
      addEdge(r*c, i, capacity);
      //printf("a %d %d %d\n", r*c , i, capacity);
   }

   for (i = 0; i < c; ++i) {
      uint32_t capacity = static_cast<uint32_t>
         (rand() % (MAX_CAPACITY - MIN_CAPACITY) + MIN_CAPACITY);
      addEdge((r - 1) * c + i, c*r + 1, capacity);
      //printf("a %d %d %d\n", (r-1)*c +i ,c*r+ 1, capacity);
   }
   startNode = numV-2;
   endNode = numV-1;
}

std::set<uint32_t>* edges;
void makeUndirectional() {

   edges = new std::set<uint32_t>[numV];
   for (uint32_t i = 0; i < numV; i++) {
      for (uint32_t a=0;a<graph[i].adj.size();a++){
         int n = graph[i].adj[a].n;
         //         printf("%d %d\n",i,n);
         edges[i].insert(n);
         edges[n].insert(i);
      }

   }

   for (uint32_t i = 0; i < numV; i++) {
      graph[i].adj.clear();
      for (uint32_t n: edges[i]) {
         Adj a;
         a.n = n;
         a.d_cm = 0;
         graph[i].adj.push_back(a);
      }

   }



}

void ConvertToCSR() {
   numE = 0;
   for (uint32_t i = 0; i < numV; i++) numE += graph[i].adj.size();
   printf("Read %d nodes, %d adjacencies\n", numV, numE);

   csr_offset = (uint32_t*)(malloc (sizeof(uint32_t) * (numV+1)));
   csr_neighbors = (Adj*)(malloc (sizeof(Adj) * (numE)));
   csr_dist = (uint32_t*)(malloc (sizeof(uint32_t) * numV));
   numE = 0;
   for (uint32_t i=0;i<numV;i++){
      csr_offset[i] = numE;
      for (uint32_t a=0;a<graph[i].adj.size();a++){
         csr_neighbors[numE++] = graph[i].adj[a];
      }
      csr_dist[i] = ~0;
   }
   csr_offset[numV] = numE;

}

struct compare_node {
   bool operator() (const Node &a, const Node &b) const {
      return a.bucket > b.bucket;
   }
};
void ComputeReference(){
   uint32_t  delta = 1;
   printf("Compute Reference\n");
   std::priority_queue<Node, std::vector<Node>, compare_node> pq;

    // cache flush
#if 0
    const int size = 20*1024*1024;
    char *c = (char *) malloc(size);
    for (int i=0;i<0xff;i++) {
       // printf("%d\n", i);

        for (int j=0;j<size;j++)
            c[j] = i*j;
    }
#endif
   uint32_t max_pq_size = 0;
   int edges_traversed = 0;

   clock_t t = clock();
   Node v = {startNode, 0, 0};
   pq.push(v);
   while(!pq.empty()){
      Node n = pq.top();
      uint32_t vid = n.vid;
      uint32_t dist = n.dist;
      //printf("visit %d %d\n", vid, dist);
      pq.pop();
      max_pq_size = pq.size() < max_pq_size ?  max_pq_size : pq.size();
      edges_traversed++;
      if (csr_dist[vid] > dist) {
         csr_dist[vid] = dist;

         uint32_t ngh = csr_offset[vid];
         uint32_t nghEnd = csr_offset[vid+1];

         while(ngh != nghEnd) {
            Adj a = csr_neighbors[ngh++];
            Node e = {a.n, dist +  a.d_cm, (dist+a.d_cm)/delta};
            //printf(" -> %d %d\n", a.n, dist+ a.d_cm);
            pq.push(e);
         }
      }
   }
   t = clock() -t;
   printf("Time taken :%f msec\n", ((float)t * 1000)/CLOCKS_PER_SEC);
   printf("Node %d dist:%d\n", numV -1, csr_dist[numV-1]);
   printf("Max PQ size %d\n", max_pq_size);
   printf("edges traversed %d\n", edges_traversed);
}

int size_of_field(int items, int size_of_item){
	const int CACHE_LINE_SIZE = 64;
	return ( (items * size_of_item + CACHE_LINE_SIZE-1) /CACHE_LINE_SIZE) * CACHE_LINE_SIZE / 4;
}


void WriteOutput(FILE* fp) {
   // all offsets are in units of uint32_t. i.e 16 per cache line

   int SIZE_DIST =((numV+15)/16)*16;
   int SIZE_EDGE_OFFSET =( (numV+1 +15)/ 16) * 16;
   int SIZE_NEIGHBORS =(( (numE* 8)+ 63)/64 ) * 16;
   int SIZE_GROUND_TRUTH =((numV+15)/16)*16;

   int BASE_DIST = 16;
   int BASE_EDGE_OFFSET = BASE_DIST + SIZE_DIST;
   int BASE_NEIGHBORS = BASE_EDGE_OFFSET + SIZE_EDGE_OFFSET;
   int BASE_GROUND_TRUTH = BASE_NEIGHBORS + SIZE_NEIGHBORS;

   int BASE_END = BASE_GROUND_TRUTH + SIZE_GROUND_TRUTH;

   uint32_t* data = (uint32_t*) calloc(BASE_END, sizeof(uint32_t));

   data[0] = MAGIC_OP;
   data[1] = numV;
   data[2] = numE;
   data[3] = BASE_EDGE_OFFSET;
   data[4] = BASE_NEIGHBORS;
   data[5] = BASE_DIST;
   data[6] = BASE_GROUND_TRUTH;
   data[7] = startNode;
   data[8] = BASE_END;

   for (int i=0;i<9;i++) {
      printf("header %d: %d\n", i, data[i]);
   }

   uint32_t max_int = 0xFFFFFFFF;
   for (uint32_t i=0;i<numV;i++) {
      data[BASE_EDGE_OFFSET +i] = csr_offset[i];
      data[BASE_DIST+i] = max_int;
      data[BASE_GROUND_TRUTH +i] = csr_dist[i];
      //printf("gt %d %d\n", i, csr_dist[i]);
   }
   data[BASE_EDGE_OFFSET +numV] = csr_offset[numV];

   for (uint32_t i=0;i<numE;i++) {
      data[ BASE_NEIGHBORS +2*i ] = csr_neighbors[i].n;
      data[ BASE_NEIGHBORS +2*i+1] = csr_neighbors[i].d_cm;
   }

   printf("Writing file \n");
   fwrite(data, 4, BASE_END, fp);
   /*
   for (int i=0;i<BASE_END;i++) {
      fprintf(fp, "%08x\n", data[i]);
   } */
   fclose(fp);

   free(data);

}
void WriteOutputColor(FILE* fp) {
   // all offsets are in units of uint32_t. i.e 16 per cache line
   //int SIZE_COLOR =((numV+15)/16)*16;
   //

   // (The expected input format for the pipelined cores differs from the one
   // for non-pipe/riscv versions. This generator is compatible with both.

   int SIZE_DATA = size_of_field(numV, 16);
   int SIZE_EDGE_OFFSET = size_of_field(numV+1, 4) ;
   int SIZE_NEIGHBORS = size_of_field(numE, 4) ;
   int SIZE_SCRATCH = size_of_field(numV, 8);
   int SIZE_GROUND_TRUTH = size_of_field(numV, 4);

   int BASE_DATA = 16;
   int BASE_EDGE_OFFSET = BASE_DATA + SIZE_DATA;
   int BASE_NEIGHBORS = BASE_EDGE_OFFSET + SIZE_EDGE_OFFSET;
   int BASE_SCRATCH = BASE_NEIGHBORS + SIZE_NEIGHBORS;
   int BASE_GROUND_TRUTH = BASE_SCRATCH + SIZE_SCRATCH;
   int BASE_END = BASE_GROUND_TRUTH + SIZE_GROUND_TRUTH;

   uint32_t* data = (uint32_t*) calloc(BASE_END, sizeof(uint32_t));
   uint32_t enqueuer_size = 16;

   data[0] = MAGIC_OP;
   data[1] = numV;
   data[2] = numE;
   data[3] = BASE_EDGE_OFFSET;
   data[4] = BASE_NEIGHBORS;
   data[5] = BASE_DATA;
   data[6] = BASE_GROUND_TRUTH;
   data[7] = BASE_SCRATCH;
   data[8] = BASE_END;
   data[9] = enqueuer_size;


   for (int i=0;i<10;i++) {
      printf("header %d: %d\n", i, data[i]);
   }

   for (uint32_t i=0;i<numV;i++) {

      data[BASE_EDGE_OFFSET + i] = csr_offset[i];
      data[BASE_SCRATCH + i*2 + 0] = 0;
      data[BASE_SCRATCH + i*2 + 1] = 0;

      data[BASE_DATA+i*4] = (csr_offset[i+1]-csr_offset[i]) << 16 | 0xffff; // degree, color
      data[BASE_DATA+i*4+1] = 0; // scratch
      data[BASE_DATA+i*4+2] = (csr_offset[i+1]-csr_offset[i]) << 16 | 0; // ndp, ncp
      data[BASE_DATA+i*4+3] = csr_offset[i];

      //printf("gt %d %d\n", i, csr_dist[i]);
   }
   data[BASE_EDGE_OFFSET + numV] = csr_offset[numV];

   for (uint32_t i=0;i<numE;i++) {
      data[ BASE_NEIGHBORS +i ] = csr_neighbors[i].n;
   }


   // sort by degree
   std::vector< NodeSort > vec;
   for (unsigned int i=0;i<numV;i++) {
      uint32_t degree = csr_offset[i+1] - csr_offset[i];
      NodeSort n = {i, degree};
      vec.push_back(n);
   }
   std::sort(vec.begin(), vec.end(), degree_sort());
   for (uint32_t i=0;i<numV;i++) {
      uint32_t vid = vec[i].vid;
      uint64_t vec = 0;
      for (uint32_t j=csr_offset[vid]; j< csr_offset[vid+1]; j++) {
         uint32_t neighbor = csr_neighbors[j].n;
         //printf("\t%d neighbor %x\n", neighbor, csr_dist[neighbor]);
         if (csr_dist[neighbor] != 0xFFFFFFFF) {
            vec = vec | ( 1<<csr_dist[neighbor]);
         }
      }
      int bit = 0;
      while(vec & 1) {
         vec >>=1;
         bit++;
      }
      csr_dist[vid] = bit;
      data[BASE_GROUND_TRUTH + vid] = bit;

      if (bit >= 28) printf("vid %d color %d\n", vid, bit);
   }

   printf("Writing file \n");
   fwrite(data, 4, BASE_END, fp);
   /*
   for (int i=0;i<BASE_END;i++) {
      fprintf(fp, "%08x\n", data[i]);
   } */
   fclose(fp);

   free(data);

}

void WriteOutputMaxflow(FILE* fp) {
   // all offsets are in units of uint32_t. i.e 16 per cache line
   // dist = {height, excess, counter, active, visited, min_neighbor_height,
   // flow[10]}
   int SIZE_DIST = size_of_field(numV, 64);
   int SIZE_EDGE_OFFSET = size_of_field(numV+1, 4);
   int SIZE_NEIGHBORS = size_of_field(numE, 8) ;
   int SIZE_GROUND_TRUTH =size_of_field(numV, 4); // redundant

   int BASE_DIST = 16;
   int BASE_EDGE_OFFSET = BASE_DIST + SIZE_DIST;
   int BASE_NEIGHBORS = BASE_EDGE_OFFSET + SIZE_EDGE_OFFSET;
   int BASE_GROUND_TRUTH = BASE_NEIGHBORS + SIZE_NEIGHBORS;
   int BASE_END = BASE_GROUND_TRUTH + SIZE_GROUND_TRUTH;

   uint32_t* data = (uint32_t*) calloc(BASE_END, sizeof(uint32_t));

   uint32_t log_global_relabel_interval = (int) (round(log2(numV))); // closest_power_of_2(numV)
   if (log_global_relabel_interval <= 5) log_global_relabel_interval = 6;

   log_global_relabel_interval = 8;

   uint32_t global_relabel_mask = ((1<<log_global_relabel_interval) -1 ) << 8;
   uint32_t iteration_no_mask = ~((1<< (log_global_relabel_interval + 8))-1);

   data[0] = MAGIC_OP;
   data[1] = numV;
   data[2] = numE;
   data[3] = BASE_EDGE_OFFSET;
   data[4] = BASE_NEIGHBORS;
   data[5] = BASE_DIST;
   data[6] = BASE_GROUND_TRUTH;
   data[7] = startNode;
   data[8] = BASE_END;
   data[9] = endNode;
   data[10] = log_global_relabel_interval;
   data[11] = global_relabel_mask;
   data[12] = iteration_no_mask;
   data[13] = 1; // ordered edges
   data[14] = 0; // bfs producer task
   data[15] = 0; // bfs is non-spec


   for (int i=0;i<14;i++) {
      printf("header %d: %x\n", i, data[i]);
   }
   //todo ground truth
   uint32_t max_degree = 0;

   for (uint32_t i=0;i<numV;i++) {
      data[BASE_EDGE_OFFSET +i] = csr_offset[i];
      data[BASE_GROUND_TRUTH +i] = csr_dist[i];
      //printf("Node %d n_edges %d %d\n", i, csr_offset[i], csr_offset[i+1]-csr_offset[i]);
      for (int j=0;j<16;j++) {
         data[BASE_DIST +i * 16 + j] = 0;
      }
      data[BASE_DIST+i*16+14] = csr_offset[i];
      data[BASE_DIST+i*16+15] = csr_offset[i+1];
      if (csr_offset[i+1] - csr_offset[i] > max_degree)
          max_degree = csr_offset[i+1]-csr_offset[i];

   }
   data[BASE_EDGE_OFFSET +numV] = csr_offset[numV];

   printf("max deg %d \n", max_degree);

   // startNode excess
   uint32_t startNodeExcess= 0;
   for (Adj e : graph[startNode].adj) {
      startNodeExcess += e.d_cm;
   }
   // dist structure 0 - excess; 1 - {8'b counter, 24'b min_neighbor_height}
   // 2 - height , 3 - visited
   data[BASE_DIST + startNode*16 +0 ] = startNodeExcess;
   data[BASE_DIST + startNode*16 +1 ] = 0;
   data[BASE_DIST + startNode*16 +2 ] = numV; // height
   printf("StartNodeExcess %d\n", startNodeExcess);

   for (uint32_t i=0;i<numE;i++) {
      data[ BASE_NEIGHBORS +i*2 ] =  (csr_neighbors[i].index << 24) + csr_neighbors[i].n;
      data[ BASE_NEIGHBORS +i*2+1 ] = csr_neighbors[i].d_cm;
      //printf("edge %2d: %2d %2d %2d \t%x\n",i, csr_neighbors[i].n, csr_neighbors[i].d_cm,
      //         csr_neighbors[i].index, (BASE_NEIGHBORS +i*2)*4);
   }
   printf("Writing file \n");
   fwrite(data, 4, BASE_END, fp);
   /*
   for (int i=0;i<BASE_END;i++) {
      fprintf(fp, "%08x\n", data[i]);
   }
   */
   fclose(fp);

   free(data);

}

void WriteDimacs(FILE* fp) {
   // all offsets are in units of uint32_t. i.e 16 per cache line

   fprintf(fp, "p sp %d %d\n", numV, numE);

   for (uint32_t i=0;i<numV;i++){
      for (uint32_t a=0;a<graph[i].adj.size();a++){
          Adj e = graph[i].adj[a];
          fprintf(fp, "a %d %d %d\n", i + 1, e.n + 1, e.d_cm);
      }
   }
}
void WriteEdgesFile(FILE *fp) {
   // for use in coloring
   fprintf(fp, "EdgeArray");
   for (uint32_t i=0;i<numV;i++){
      for (uint32_t a=0;a<graph[i].adj.size();a++){
          Adj e = graph[i].adj[a];
          fprintf(fp, "%d %d\n", i + 1, e.n + 1);
      }
   }

}

int main(int argc, char *argv[]) {

   // 0 - load from file .bin format
   // 1 - grid graph
   char out_file[50];
   char dimacs_file[50];
   char edgesFile[50];
   char ext[50];
   if (argc < 3) {
      printf("Usage: graph_gen app type=<latlon,grid,gr,color> type_args\n");
      exit(0);
   }
   if (strcmp(argv[1], "sssp") ==0) {
      app = APP_SSSP;
      sprintf(ext, "%s", "sssp");
   }
   if (strcmp(argv[1], "color") ==0) {
      app = APP_COLOR;
      sprintf(ext, "%s", "color");
   }
   if (strcmp(argv[1], "flow") ==0) {
      app = APP_MAXFLOW;
      sprintf(ext, "%s", "flow");
   }

   startNode = 0;
   if (strcmp(argv[2], "latlon") ==0) {
      // astar type
      LoadGraph(argv[3]);
      int strStart = 0;
      // strip out filename from path
      for (uint32_t i=0;i<strlen(argv[3]);i++) {
         if (argv[3][i] == '/') strStart = i+1;
      }
      sprintf(out_file, "%s.%s", argv[3] +strStart, ext);
   } else if (strcmp(argv[2], "grid") == 0) {
      int r, c;
      if (app==APP_MAXFLOW) {
         r = atoi(argv[3]);
         c = atoi(argv[4]);
         int n_connections = atoi(argv[5]);
         GenerateGridGraphMaxflow(c, r, n_connections);
      } else {
         r = atoi(argv[3]);
         c = r;
         GenerateGridGraph(r);
      }
      sprintf(out_file, "grid_%dx%d.%s", r,c, ext);
      sprintf(dimacs_file, "grid_%dx%d.dimacs", r,c);
   } else if (strcmp(argv[2], "gr") == 0) {
      LoadGraphGR(argv[3]);
      int strStart = 0;
      // strip out filename from path
      for (uint32_t i=0;i<strlen(argv[3]);i++) {
         if (argv[3][i] == '/') strStart = i+1;
      }
      sprintf(out_file, "%s.%s", argv[3] +strStart, ext);
      sprintf(edgesFile, "%s.edges", argv[3] +strStart);
   } else if (strcmp(argv[2], "color") == 0) {
      // coloring type : eg: com-youtube
      LoadGraphEdges(argv[3]);
      int strStart = 0;
      // strip out filename from path
      for (uint32_t i=0;i<strlen(argv[3]);i++) {
         if (argv[3][i] == '/') strStart = i+1;
      }
      sprintf(out_file, "%s.%s", argv[3] +strStart, ext);
   }
   if (app == APP_COLOR) {
      makeUndirectional();
   }

   ConvertToCSR();

   if (app == APP_SSSP) {
      ComputeReference();
   }

   FILE* fp;
   fp = fopen(out_file, "wb");
   printf("Writing file %s %p\n", out_file, fp);
   //fpd = fopen(dimacs_file, "w");
   //WriteDimacs(fpd);
   //fpd = fopen(edgesFile, "w");
   //WriteEdgesFile(fpd);
   //fclose(fpd);
   if (app == APP_SSSP) {
      WriteOutput(fp);
   } else if (app == APP_COLOR) {
      WriteOutputColor(fp);
   } else if (app == APP_MAXFLOW) {
      WriteOutputMaxflow(fp);
   }
   return 0;
}
